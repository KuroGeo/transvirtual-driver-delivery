---
name: engineering-requirements-extract
description: Extract traceable engineering requirements and acceptance contracts from a prototype, product brief and architecture. Use before agent delegation, when design sources conflict, or when scope must become testable work; not for inventing a new product.
---

# Engineering Requirements Extract

把已有信息变成另一名 Agent 可以开发、测试和验收的行为合同。原型说明当前交互，架构说明目标可靠性；两者都不证明实现已交付。

## 输入与来源

读取用户最新范围、项目指令、原始题目/PRD、当前原型及其最新修正、架构和源码状态。按 [提取规则](references/extraction.md) 处理冲突。优先解析文本和现有数据；需要浏览器交互时遵守项目路由与后台规则。

对每条重点需求记录：稳定 ID、输入/触发、可观察结果、错误/恢复行为、数据不变量、来源、完成所需证据和负责人。不能把“生产级”“流畅”“可靠”直接当可验收要求。

## 交付

1. 需求矩阵：每条能对应开发任务、测试和用户验收。
2. 接口合同：模型身份、状态机、成功/失败定义、异步顺序和共享所有权；具体 API 命名留给指定接口负责人冻结。
3. 任务依赖图：谁先确定什么，哪些可并行，哪些需要设备/服务。
4. 决策清单：区别已确认、工程默认值、实施时核验和外部阻塞。不得替用户购买服务或承诺新功能。

复用 [需求模板](assets/requirements-template.md)。资料足够时直接写出合同，只询问会显著改变行为且资料不能确定的事项。与已有需求合并，避免每个 Agent 重新写一份 PRD。

## 完成标准

重点业务链和故障路径均可追溯；当前功能与后续功能分开；历史证据层级正确；冲突有明确决议或负责人。提取结束只交回合同，不自动开始实现或发布。
