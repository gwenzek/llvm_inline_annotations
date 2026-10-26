define void @generic() {
  call void @memcpy(ptr %a, ptr %b, i64 8), !dbg !3
  call void @memcpy(ptr %a, ptr %b, i64 256), !dbg !3
  call void @memset(ptr %a, i8 0, i64 16), !dbg !3
  call void @memset(ptr %a, i8 0, i64 %n), !dbg !3
  call void @foo(), !dbg !3
  call void @foo(), !dbg !3
  invoke void @other()
          to label %ok unwind label %fail, !dbg !4
  call void @without_debug()
  call void @unresolved(), !dbg !999
}
!0 = distinct !DICompileUnit(language: DW_LANG_C99, file: !1, isOptimized: true)
!1 = !DIFile(filename: "src/../missing.zig", directory: "/nonexistent/workspace")
!2 = distinct !DISubprogram(name: "generic", file: !1, line: 1)
!3 = !DILocation(line: 1904, column: 7, scope: !2, inlinedAt: !4)
!4 = !DILocation(line: 2, column: 1, scope: !2)
