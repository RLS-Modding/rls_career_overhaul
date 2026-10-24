# Contributing to RLS Career Overhaul

Bug reports, fixes, translations and ideas are welcome. Search the existing issues and PRs first so related work stays together.

## Report a problem

Use the bug report form and include the exact BeamNG and Overhaul versions. Add the map name and version when relevant, the steps to reproduce, and what happened instead of what you expected.

A short video, screenshot or session log can help. Back up an affected save before testing, and check logs for personal information before uploading them. You do not need to delete your saves or reset all your controls to file a report.

For an idea, use the feature request form and explain what you want to do and how it would help.

## Send a PR

1. Fork this repo and create a branch from the latest `main`.
2. Keep the PR focused on one fix or feature. Leave unrelated cleanup for another PR.
3. Explain the problem, the change and how you checked it. Link the issue if there is one.
4. Add before/after images for visible changes. For a gameplay fix, include the steps and versions used to test it.

If something could not be tested, say so. A useful partial fix is easier to review when its limits are clear.

`main` can contain accepted changes that are not in a release yet. Use the named ZIP from [Releases](https://github.com/RLS-Modding/rls_career_overhaul/releases/latest) for the latest public download.

## Licenses and credit

Keep existing copyright, license and contributor notices. This repository contains files under different terms; see [Licensing](LICENSING.md) and [third-party notices](THIRD_PARTY_NOTICES.md).

For new original mod code, use **AGPL version 3 only** with the project's [BeamNG additional permission](licenses/RLS-BeamNG-Permission.txt). You retain copyright in your contributions. Use accurate author attribution; contributing does not transfer your copyright to RLS Modding.

Files covered by bCDDL or another upstream license keep those terms, including applicable terms for modifications. Do not replace an upstream notice with an AGPL-only header. If you include someone else's code or assets, identify the source and applicable permission in the PR.

Maintainers check new files' license notices and update the [exact RLS source scope](licenses/RLS-AGPL-SCOPE.md) where applicable. A folder name alone does not put every file under the same license. We keep contributor credit when adapting accepted work for dev.

## How we handle public and dev PRs

We also maintain a development repo. For an accepted code change, a maintainer prepares a matching dev PR and tests the fix there. You do not need access to that repo or have to make the second PR yourself.

The implementation may differ if the development code has moved or changed. Both versions should solve the same problem. We keep the public PR updated with a readable summary of the development work and test results; links to development PRs may require access.

Once both versions are ready, we merge the public PR and its matching dev PR. Your public contribution gets a merged PR and credit. A documentation-only change may only need a public PR.

The next public release includes the tested development version. We check that it preserves accepted public fixes before merging the release PR. If a contribution needs a different approach, we discuss it in the PR rather than silently replacing the behavior.

## Maintainer checklist

- Review the reported problem and agree on the intended behavior.
- Create the matching dev PR for code changes. Record the public PR link there, and add a development summary to the public PR.
- Test the relevant behavior, including save/reload, input, map or payment paths when the change affects them. Record what passed and what remains untested.
- Confirm the public and dev changes produce the same intended result, then merge both PRs. Keep the contributor's credit when adapting their code.
- Before a public release, reconcile all public changes since the last release with dev. Include fixes for existing saves when required; fixing new data alone may leave old saves broken.
- Refresh the packaged mod files on a branch from public `main`. Preserve the README, this guide, `.github` templates, licensing documents and applicable source/component notices. Review intended file removals.
- Check the release diff for lost contributions and unrelated changes. Test the named release ZIP before publishing it.

## Keep replies useful

Write short, plain replies about the problem and the next step. Explain what was checked and ask for specific missing details. Avoid commit hashes and automated-review output in support replies, and only call a report fixed after the relevant behavior has been verified.

When closing a duplicate or an already-covered PR, link the matching report or explain where the behavior is covered. Thank the contributor and preserve any useful reproduction details.
