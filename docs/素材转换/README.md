# 素材文档转换工具

这个目录存 **不参与游戏运行** 的文档工具。`.gdignore` 让 Godot 忽略整个目录
（否则 `docs/` 下的 PNG 会被引擎当成纹理导入，生成一堆没用的 `.import`）。

## md转docx.py

把 `docs/素材制作规范_人工.md` 和 `docs/素材清单.md` 转成 Word 版
（`docs/素材制作规范_人工.docx`、`docs/素材清单.docx`），给外部美术看。

```powershell
& "C:\Users\a1981\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe" "docs\素材转换\md转docx.py"
```

> Python 路径换成你自己环境里带 `python-docx` 的那个即可。

### 已知限制（改之前先看）

- **Word 版不使用表格**。Markdown 里的表格会被展开成「小标题 + 字段：值」的段落列表。
  这是刻意的：实测渲染器对含中文的表格单元格不做正常断行，长内容会画出单元格甚至出纸面，
  调列宽、换纸张方向、加 `w:tblW`/`w:tblLayout`/CJK 断行设置都无法稳定解决。
  **表格原件保留在 Markdown 里**，要表格就改 Markdown。
- 含下划线的行内代码（如 `ground-lawn_edge`）在个别行仍可能贴到右边缘，属同一渲染器问题。
- 改了 Markdown 之后重新跑一次本脚本，Word 版才会同步。
