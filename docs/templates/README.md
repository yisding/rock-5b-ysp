# Documentation interface templates

These templates illustrate the repository-wide document contracts in
[`CONTRIBUTING.md`](../../CONTRIBUTING.md). They make ownership, evidence,
boundaries, and handoff routes recognizable across projects without imposing a
fixed schema. Copy only the relevant sections, replace every placeholder, and
keep project-specific detail where it helps the intended reader.

| Template | Use it for |
|----------|------------|
| [`project-readme.md`](project-readme.md) | A project front door that routes scope, maintained model, operation, evidence, and next proof. |
| [`technical-explanation.md`](technical-explanation.md) | A durable mechanism or architecture explanation led by the maintained result. |
| [`runbook.md`](runbook.md) | An executable build, install, recovery, or validation operation. |
| [`live-plan.md`](live-plan.md) | The canonical future-work ladder for a sustained workstream. |
| [`dated-audit.md`](dated-audit.md) | A frozen pin-specific inspection or decision basis that remains useful. |

Fresh observations use [`findings/TEMPLATE.md`](../../findings/TEMPLATE.md)
instead. A mature finding is incorporated into these existing owner types only
when its useful content fits their role; the finding itself is then removed
after maintained links are repointed.
