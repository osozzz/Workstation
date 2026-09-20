# Issue and Project Model

## Issues

Issues are the executable units of work and should carry:

- objective;
- scope;
- acceptance criteria;
- verification/evidence;
- dependencies and relationships;
- risks/constraints;
- references where applicable.

Use parent/sub-issues and native relationships for decomposition and blocking. Do not encode dependency state as a fake status.

## GitHub Project

The intended project is **Workstation — Development**.

Recommended status flow:

- Backlog
- Ready
- In Progress
- Review
- Done

Recommended project fields:

- Status
- Priority
- Area
- Risk

Do not recreate these project fields as parallel labels.

## Labels

Labels classify the nature of work and should remain restrained. The initial intended set is:

- bug
- documentation
- enhancement
- maintenance
- security
- testing
- dependencies
- validation

## Ownership

Repository Issues should be assigned to the project owner when they are active work items.
