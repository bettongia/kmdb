# Plans

The `plans/` directory contains a set of plans that describe a problem and the
implementation plan to resolve it.

IMPORTANT: When asked to plan something do not commence implementation until
explicitly told to do so. The only file you should edit during planning is the
plan file.

Be confident in providing feedback on the problem statement. If you don't think
it's a good idea, say so and explain why.

Implementation work on a plan should follow the guidance provided in
[CLAUDE.md](../CLAUDE.md) with these additional elements:

1. Create a Git branch for the implementation work and use a Git worktree to
   undertake the work - use the `.worktrees` directory in the project base to
   house worktrees. The branch should use the date and plan name as the prefix -
   e.g. `20260401_plan_cli{_other detail if required}`.
2. Update the plan file as you go, especially the status field and task lists.
   Use the version of the plan file in the worktree.
3. Use check lists in the implementation plan and check off work as you go. That
   way we can continue work effectively after an interruption.
4. All implementation work must include writing tests (and ensuring they pass)
   and updating documentation (Code docs, user and spec docs etc) as
   appropriate. If the work introduces a test that cannot run in the automated
   suite (a real cloud service, real-OS durability/`fsync`, cross-process or
   multi-host concurrency, etc.), add an entry describing it to the release
   checklist at `docs/spec/28_release_checklist.md` so it is run at release time.
5. When the plan has been completely implemented, make sure the status is
   updated to "Complete" and move the plan into the `plans/completed` directory.
6. When you complete the implementation work, submit the changes as a pull
   request.

**Spec section numbering:** Spec files in `docs/spec/` are numbered sequentially
(`NN_topic.md`) and the spec is built serially as work is done. A plan that will
add a spec section must **not** hard-code its number — refer to the spec by topic
and take the next available `NN` when the file is actually created. This prevents
number collisions between plans drafted in parallel.

## Plan template

Each plan needs to contain the following sections:

1. A title that succinctly describes the issue at hand
2. The status, being one of:
   1. "Open" - not started
   2. "Investigated" - the investigation has been undertaken
   3. "Questions" - the investigation has lead to questions that need to be
      reviewed and answered. Once all questions have been answered, move the
      plan to "Investigated" state.
   4. "Implementing" - indicates that implementation work has started.
   5. "Complete" - the implementation work has been carried out
3. A link to the Pull Request (PR) submitted once the implementation work has
   been completed.
4. A problem statement that outlines what the plan is trying to achieve
5. An investigation that describes the investigation into the problem, calling
   out key files, likely edge cases and recommendations for implementing a
   solution.
6. A set of any open questions that need to be resolved before determining the
   implementation plan.
7. The implementation plan that describes how you will undertake the work. Use
   checklists to mark off work items as you complete them.
8. A summary statement of the work undertaken.

If you're working on a plan document that does not match this format, please
feel free to update the plan document as appropriate.

### Base template

```markdown
# {Plan title}

**Status**: {Open | Investigated | Questions | Implementing | Complete}

**PR link**: {A link to the PR submitted for this plan}

## Problem statement

{Problem statement text}

## Open questions

{A checklist of open questions, mark each one off as they are answered}

## Investigation

{Investigation notes}

## Implementation plan

{Checklists and notes for the implementation work}

## Summary

{Dot points highlighting the work undertaken}
```
