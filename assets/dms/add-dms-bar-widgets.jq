# 把 DMS 插件控件接到状态栏：只增不覆盖、幂等、没有 barConfigs 时什么都不做。
#
# 为什么不放进 desktop-settings.json：那份文件走的是 `jq '.[0] * .[1]'` 浅合并，
# 数组会被整体替换——barConfigs 一旦进去，每次重装都会清掉用户自己的状态栏布局。
#
# **没有现成的 barConfigs 时什么都不做。** DMS 读设置是整体赋值（`root[k] = raw`），
# 它的默认状态栏（启动器/工作区/焦点窗口、音乐/时钟/天气、系统托盘/剪贴板/CPU/内存/
# 通知/电池/控制中心）只在"键不存在"时生效。如果在这里凭空造一个只含插件控件的栏，
# 全新机器上用户会得到一个几乎是空的顶栏——这比"控件没显示"严重得多。宁可少显示。
#
# 参数（--argjson widgets）形如：
#   {"left": ["localTranslate", "phoneConnect"], "right": ["localStatus"]}
# 语义：
#   1. 只动第一个栏（barConfigs[0]），与旧版只把用量控件接到主栏的行为一致；
#   2. 已经出现在任意栏的控件（字符串或对象形式）保持原位、原设置，绝不移动/去重；
#   3. 缺失的控件按参数顺序追加到指定一侧，写成 {"id": ..., "enabled": true}；
#   4. 重复执行不会产生第二个同名控件。
def widget_id: if type == "object" then .id else . end;

def present_ids:
    [.barConfigs[]?
     | (.leftWidgets? // [])[], (.centerWidgets? // [])[], (.rightWidgets? // [])[]
     | widget_id];

if ((.barConfigs // []) | length) == 0 then
    .
else
    present_ids as $present
    | .barConfigs[0].leftWidgets =
        ((.barConfigs[0].leftWidgets // [])
         + [($widgets.left // [])[]
            | select(. as $id | ($present | index($id)) == null)
            | {"id": ., "enabled": true}])
    | .barConfigs[0].rightWidgets =
        ((.barConfigs[0].rightWidgets // [])
         + [($widgets.right // [])[]
            | select(. as $id | ($present | index($id)) == null)
            | {"id": ., "enabled": true}])
end
