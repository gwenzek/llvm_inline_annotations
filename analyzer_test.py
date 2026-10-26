import json
from pathlib import Path
import tempfile
import unittest

import analyzer


METADATA = '''
!0 = distinct !DICompileUnit(language: DW_LANG_C99, file: !1, isOptimized: true)
!1 = !DIFile(filename: "zml/test.zig", directory: "/sandbox/execroot/_main")
!2 = distinct !DISubprogram(name: "generic", scope: !1, file: !1, line: 1)
!3 = !DILexicalBlock(scope: !2, file: !1, line: 1, column: 1)
!4 = !DILocation(line: 2, column: 4, scope: !3, inlinedAt: !5)
!5 = !DILocation(line: 3, column: 2, scope: !2)
!6 = !DILocation(line: 0, scope: !2)
'''


class AnalyzerTest(unittest.TestCase):
    def test_full_panic_calls_are_ignored(self):
        report = self.analyze('''
  call void @"debug.FullPanic((function 'defaultPanic')).outOfBounds"(), !dbg !4
  call void @"debug.FullPanic((function 'customPanic')).unwrapError"(), !dbg !4
  call void @debug.panic__func_123(), !dbg !4
''')
        self.assertEqual([d["callee"] for d in report["diagnostics"]], ["debug.panic__func_123"])
        report["diagnostics"].append({"kind": "call", "callee": "debug.FullPanic(...).outOfBounds", "path": "zml/test.zig", "line": 2})
        analyzer.apply(report, self.root, ["zml"])
        self.assertNotIn("FullPanic", self.source.read_text())
        self.assertIn("debug.panic__func_123", self.source.read_text())

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "zml/test.zig"
        self.source.parent.mkdir()
        self.source.write_text("fn generic() void {\n    work(); // original\n}\n")

    def analyze(self, body, metadata=METADATA):
        ir = self.root / "test.ll"
        ir.write_text(body + metadata)
        return analyzer.analyze([ir], {"zml/test.zig": str(self.source)})

    def test_worst_generic_instance_and_lexical_origin(self):
        report = self.analyze('''
  call void @llvm.memcpy.p0.p0.i64(ptr %a, ptr %b, i64 8, i1 false), !dbg !4
  call void @llvm.memcpy.p0.p0.i64(ptr %a, ptr %b, i64 256, i1 false), !dbg !4
  call void @llvm.memset.p0.i64(ptr %a, i8 0, i64 16, i1 false), !dbg !4
  call void @llvm.memset.p0.i64(ptr %a, i8 0, i64 %n, i1 false), !dbg !4
  tail call void @"generic(i32)"(), !dbg !4
  call void @"generic(i32)"(), !dbg !4
  call void %fp(), !dbg !4
  call void @llvm.lifetime.end.p0(ptr %a), !dbg !4
''')
        diagnostics = report["diagnostics"]
        self.assertEqual(len(diagnostics), 4)
        self.assertTrue(all(d["line"] == 2 for d in diagnostics))
        self.assertEqual(next(d["bytes"] for d in diagnostics if d["kind"] == "memcpy"), 256)
        self.assertIsNone(next(d["bytes"] for d in diagnostics if d["kind"] == "memset"))

    def test_memory_attributes_and_libc(self):
        self.assertEqual(analyzer.operation('call void @llvm.memcpy.p0.p0.i64(ptr align 8 dereferenceable(64) %a, ptr %b, i64 64, i1 false), !dbg !4'), {"kind": "memcpy", "bytes": 64})
        self.assertEqual(analyzer.operation('%r = call ptr @memmove(ptr %a, ptr %b, i64 128), !dbg !4'), {"kind": "memmove", "bytes": 128})
        self.assertEqual(analyzer.operation('call void %memcpy(), !dbg !4'), {"kind": "call", "callee": "<indirect>"})
        self.assertIsNone(analyzer.operation('call void asm sideeffect "nop", ""(), !dbg !4'))

    def test_memory_instance_counts_and_evidence(self):
        report = self.analyze('''define void @generic() {
  call void @llvm.memcpy.p0.p0.i64(ptr %dst, ptr %src, i64 168, i1 false), !dbg !4
  call void @llvm.memset.p0.i64(ptr %dst, i8 0, i64 264, i1 false), !dbg !4
  call void @llvm.memset.p0.i64(ptr %other, i8 0, i64 32, i1 false), !dbg !4
}
''')
        copy, fill = report["diagnostics"]
        self.assertEqual(copy["instance_count"], 1)
        self.assertEqual(analyzer.description(copy), "memcpy (168 bytes)")
        self.assertEqual(fill["instance_count"], 2)
        self.assertEqual(analyzer.description(fill), "memset (max 264 bytes)")
        self.assertEqual([i["bytes"] for i in fill["instances"]], [264, 32])
        evidence = copy["instances"][0]
        self.assertEqual(evidence["function"], "generic")
        self.assertEqual(evidence["ir_line"], 2)
        self.assertEqual(evidence["column"], 4)
        self.assertIn("ptr %src", evidence["instruction"])
        # Equal sizes still have multiple recorded instances.
        report = self.analyze('''
  call void @memset(ptr %a, i8 0, i64 8), !dbg !4
  call void @memset(ptr %b, i8 0, i64 8), !dbg !4
''')
        self.assertEqual(analyzer.description(report["diagnostics"][0]), "memset (max 8 bytes)")

    def test_invoke_multiline_and_unmapped(self):
        report = self.analyze('''
  invoke void @foo()
          to label %ok unwind label %fail, !dbg !4
  call void @bar(
      i64 12), !dbg !5
  call void @baz()
  call void @quux(), !dbg !6
''')
        self.assertEqual(len(report["diagnostics"]), 2)
        self.assertEqual(report["unmapped"], {"calls_without_debug_location": 1, "calls_outside_sources": 1})

    def test_reject_debug_or_stripped_ir(self):
        for metadata in ("", METADATA.replace("isOptimized: true", "isOptimized: false")):
            with self.assertRaisesRegex(ValueError, "optimized DICompileUnit"):
                self.analyze("", metadata)

    def test_invalid_generated_debug_location_is_report_only(self):
        report = self.analyze("  call void @foo(), !dbg !4\n", METADATA.replace("line: 2, column: 4", "line: 1904, column: 4"))
        self.assertEqual(report["diagnostics"], [])
        self.assertEqual(report["invalid_debug_locations"], [{"path": "zml/test.zig", "line": 1904}])

    def test_repeat_apply_remove_and_stale_report(self):
        report = self.analyze("  call void @foo(), !dbg !4\n")
        original = self.source.read_text()
        self.assertEqual(analyzer.apply(report, self.root, ["zml"], check=True)[0], 1)
        self.assertEqual(self.source.read_text(), original)
        self.assertEqual(analyzer.apply(report, self.root, ["zml"])[0], 1)
        annotated = self.source.read_text()
        self.assertIn('// original // llvm-ir: not inlined: "foo"', annotated)
        self.assertEqual(annotated.count("\n"), original.count("\n"))
        self.assertEqual(analyzer.apply(report, self.root, ["zml"])[0], 0)
        self.assertEqual(analyzer.apply(report, self.root, ["zml"], remove=True)[0], 1)
        self.assertEqual(self.source.read_text(), original)
        self.source.write_text(original + "// changed\n")
        with self.assertRaisesRegex(ValueError, "source changed"):
            analyzer.apply(report, self.root, ["zml"])

    def test_strings_are_not_comments(self):
        literal = 'const s = " // llvm-ir: example";\n'
        self.assertEqual(analyzer.clean_source(literal), literal)
        self.assertEqual(analyzer.clean_source(literal.rstrip("\n") + analyzer.MARKER + "memset\n"), literal)
        multiline = '    \\\\text // llvm-ir: string data\n'
        self.assertEqual(analyzer.clean_source(multiline), multiline)
        self.source.write_text("fn f() void {\n" + multiline + "}\n")
        report = self.analyze("  call void @foo(), !dbg !4\n")
        count, skipped = analyzer.apply(report, self.root, ["zml"])
        self.assertEqual(count, 0)
        self.assertEqual(skipped, ["zml/test.zig:2"])

    def test_path_boundaries_and_external_files(self):
        for filename in ("other/zml/test.zig", "external/pkg/zml/test.zig"):
            metadata = METADATA.replace('"zml/test.zig"', json.dumps(filename)).replace('"/sandbox/execroot/_main"', '""')
            report = self.analyze("  call void @foo(), !dbg !4\n", metadata)
            if filename.startswith("external"):
                self.assertEqual(report["diagnostics"], [])
        report = self.analyze("  call void @foo(), !dbg !4\n")
        report["sources"] = {"../escape.zig": "bad"}
        with self.assertRaisesRegex(ValueError, "escapes workspace"):
            analyzer.apply(report, self.root, [".."])


if __name__ == "__main__":
    unittest.main()
