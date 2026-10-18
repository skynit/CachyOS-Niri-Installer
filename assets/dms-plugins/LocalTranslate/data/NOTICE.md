# 内置词库署名与许可

本目录的 `cedict.txt.gz` 来自 **CC-CEDICT**，由 CC-CEDICT 社区维护，MDBG 发布。

- 词库主页：https://www.mdbg.net/chinese/dictionary?page=cc-cedict
- 项目主页：https://cc-cedict.org/wiki/
- 下载地址：https://www.mdbg.net/chinese/export/cedict/cedict_1_0_ts_utf-8_mdbg.txt.gz
- 上游快照时间：2026-09-14T05:30:59Z
- 收录记录数：125,061
- 原始参考作品：CEDICT，Copyright (C) 1997, 1998 Paul Andrew Denisowski

CC-CEDICT 按 **Creative Commons Attribution-ShareAlike 4.0 International（CC BY-SA 4.0）** 授权。
完整许可见 [CC-BY-SA-4.0.txt](CC-BY-SA-4.0.txt) 和 https://creativecommons.org/licenses/by-sa/4.0/ 。

`dictionary.sqlite3` 是 LocalTranslate 生成的派生索引，同样按 **CC BY-SA 4.0** 授权。转换保留简体、繁体、数字声调拼音与全部英文释义，并新增归一化查询键和英文反向索引；其中英文查询键会移除括号说明及部分冠词、不定式前缀。生成程序为本插件目录的 `build_dictionary.py`（仓库路径 `LocalTranslate/build_dictionary.py`）。这些转换不代表上游认可本插件。

`manifest.json` 记录来源、版本与 SHA-256 校验值。分发词库或派生索引时，应保留本署名、许可和变更说明；对词库的再修改须遵循相同许可的要求。

此许可说明仅针对词库和派生数据，不替插件源码另行指定许可。
