# 把 agents 用量控件加到状态栏右侧，且**只在尚未存在时**添加。
#
# 为什么不放进 desktop-settings.json：那份文件走的是 `jq '.[0] * .[1]'` 浅合并，
# 数组会被整体替换——barConfigs 一旦进去，每次重装都会清掉用户自己的状态栏布局。
#
# 幂等：重复执行不会出现第二个同名控件。
def widget_id: if type == "object" then .id else . end;

def widget_present:
    [.barConfigs[]?
     | (.leftWidgets? // [])[], (.centerWidgets? // [])[], (.rightWidgets? // [])[]
     | widget_id] | index("cachyosAgents") != null;

if widget_present then
    .
elif ((.barConfigs // []) | length) == 0 then
    .barConfigs = [{
        "leftWidgets": [],
        "centerWidgets": [],
        "rightWidgets": [{"id": "cachyosAgents", "enabled": true}]
    }]
else
    .barConfigs[0].rightWidgets =
        ((.barConfigs[0].rightWidgets // []) + [{"id": "cachyosAgents", "enabled": true}])
end
