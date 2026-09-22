# PowerShell pipeline template

This repository hosts reusable GitHub Actions workflows and their PowerShell implementation. Consumer repositories call the workflows directly; they do not need to copy `.github/repository-discovery` into their source tree.

## Use a reusable workflow

Copy the relevant small caller workflow from [`examples/consumer-workflows`](examples/consumer-workflows) into the consumer repository's `.github/workflows` directory. The example files contain triggers and a call into this repository. They use `@main` and `pipeline_ref: main`, so central changes are picked up without editing consumer repositories.

For example:

```yaml
name: Validate applications

on:
  push:
    branches-ignore: [main]
  pull_request:
    branches-ignore: [main]
  workflow_dispatch:

permissions:
  actions: write
  contents: read

jobs:
  validate:
    uses: synapptech-devops/pipeline-template-powershell/.github/workflows/validate-changed-applications.yml@main
    with:
      pipeline_ref: main
```

The reusable workflow checks out the consumer repository as the build source and checks out this repository separately under `pipeline/` for its scripts. It uses the consumer repository as the source root and places temporary manifests and build artifacts under the pipeline checkout for the duration of the run.

## Consumer repository requirements

- The organization must provide self-hosted Windows and Linux runners with the labels `self-hosted`, `Windows`/`linux`, and `X64` as used by the workflow matrices. Docker jobs require Docker on the selected runner.
- Configure the `release-candidate`, `qa`, and `production` GitHub environments, including any required reviewers and production URL variable.
- Grant the caller workflow the permissions needed by the selected workflow. For example, validation needs `actions: write` and `contents: read`; release creation and promotion also need `contents: write` and `packages: write`.
- If this template repository is private, provide a repository or organization secret named `PIPELINE_TOKEN` with read access to it, and pass it through the reusable-workflow call. Public repositories can use the caller's `GITHUB_TOKEN`.
- Enable Actions access between the template repository and consumer repositories when the template repository is private.
- Apps opt in through the existing discovery convention: add `cicd: true` to a supported project file or package manifest.

The full workflow catalog and inputs are shown in the example caller files. The workflows that require manual values (release candidate creation, promotion, rebuild, and development artifact publishing) declare those values as reusable-workflow inputs.

## Updating centrally

Make changes here and push them to `main` to update consumers centrally. For controlled rollouts, maintain a release branch or tag and update both the reusable-workflow reference and `pipeline_ref` in a consumer caller. The two references should identify the same pipeline revision; workflows that call another reusable workflow internally currently use the central `main` branch, so those internal references must also be moved together before adopting a pinned release.

The workflows keep their existing direct triggers in this repository for maintaining and operating the template itself. Consumer repositories should use the caller examples and should not copy the implementation files.
