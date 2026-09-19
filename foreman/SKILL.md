---
name: foreman
description: 使用 Foreman 外派执行器并管理其票、线程、验收和收尾。用户明确要求 Foreman 外派，或任务涉及已有 Foreman 票或线程时使用；普通调研、排查和代码审查不触发。
metadata:
  version: "1.5.10"
---

# Foreman

Foreman 是本地 Agent 外派框架。按用户或项目规则已选定的执行通道工作；本 skill 不因“调研”“排查”“review”等通用词自动启动编排或派发。

## 按需读取

- **分工、通道选择、角色档位、任务书、审核与交付判定**：读 [通用编排指导](references/orchestration-guide.md) 的相关阶段。指导也供宿主子 agent 使用，不要求 Foreman 初始化。
- **实际配置或调用 Foreman 外派执行器**：读 [外派操作手册](references/foreman-operations.md) 的相关章节，包含初始化、权限边界、对象模型、派发、线程生命周期和命令速查。
- **编写任务书、复审要求或验收包**：按需读 [模板](references/issue-pr-flow.md)。
- **修改执行器、诊断协议或配置问题**：分别读 [Codex app-server](references/codex-app-server.md)、[Claude Code CLI](references/claude-code-cli.md)、[pi CLI](references/pi-cli.md) 或 [项目配置](references/project-config.md)。

不要预读全部文档。只使用宿主子 agent 或仅查通用编排指导时，不加载 Foreman 操作手册、不运行 setup/init/doctor。用户明确要求亲自执行或不派发时遵循该要求。

执行权限仍受用户授权及项目规则约束；合并由人执行。分工指导和脚本操作分别在上述文档维护，不在入口重复展开。
