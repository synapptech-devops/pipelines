# Reusable PowerShell pipelines

This repository contains reusable GitHub Actions workflows and the PowerShell implementation they run. A consuming repository keeps only a small caller workflow under `.github/workflows`; it does not need copies of the pipeline scripts or tests.

The central repository is [`synapptech-devops/pipelines`](https://github.com/synapptech-devops/pipelines). The examples use its `main` branch, which means changes merged to `main` are used by consumers on their next run.

## How it works

Each caller workflow declares the events that should start it and calls one workflow in this repository. The reusable workflow checks out two repositories into the runner workspace:

1. The consumer repository, as the source code to discover, build, test, and package.
2. This pipeline repository, under the `pipeline/` directory, for workflow scripts and test fixtures.

Temporary manifests and build output are kept under that pipeline checkout during the run. The consumer does not need `.github/repository-discovery` or any of its PowerShell files.

## Before you start

### 1. Decide how to share the pipeline repository

The examples work whether the pipeline repository is public or private.

- **Public pipeline repository:** no additional checkout credential is needed.
- **Private pipeline repository:** in the pipeline repository, open **Settings → Actions → General → Access** and allow the consumer repositories (or the appropriate organization) to use its workflows. Also provide a `PIPELINE_TOKEN` secret to the consumer workflows. The token must have read access to the pipeline repository. The caller examples pass this secret to the reusable workflow.

The pipeline checkout uses `PIPELINE_TOKEN` when supplied and otherwise falls back to the caller's `GITHUB_TOKEN`. A caller's `GITHUB_TOKEN` normally cannot read a different private repository, so the private-repository access setting and token are both needed. Follow your organization’s token policy when choosing a fine-grained token or GitHub App token.

### 2. Configure Actions access and permissions

In each consumer repository, enable GitHub Actions and make sure its Actions policy allows the reusable workflow in `synapptech-devops/pipelines`. Organization or enterprise policies can also restrict which actions and reusable workflows are allowed.

The caller workflow must grant the permissions needed by the selected pipeline. Use the example's `permissions` block as a starting point; do not grant write permissions to workflows that only validate code.

| Caller workflow                      | Permissions used                                                                    |
| ------------------------------------ | ----------------------------------------------------------------------------------- |
| Validate changed applications        | `actions: write`, `contents: read`                                                  |
| Manually build affected applications | `actions: read`, `contents: read`; add `packages: write` when publishing containers |
| Create release candidates            | `contents: write`, `packages: write`                                                |
| Publish development artifacts        | `actions: read`, `contents: read`, `packages: write`                                |
| Promote a candidate to production    | `contents: write`, `packages: write`                                                |
| Generate the environment manifest    | `contents: write`                                                                   |

### 3. Set up self-hosted runners

The workflows currently target self-hosted runners. The organization must have runners registered and available to each consumer repository with these labels:

- Windows runner: `self-hosted`, `Windows`, `X64`.
- Linux runner: `self-hosted`, `Linux` (or the matrix label `linux`). The Docker image build and publish jobs use a Linux runner.
- Matrix builds also select runners using the `windows` or `linux` label according to the app and its Dockerfile.

Install Docker on Linux runners used for image builds. Windows legacy .NET projects need MSBuild/Visual Studio Build Tools; modern .NET and Node projects use the corresponding setup actions. Keep any required organization-level runner groups accessible to the consumer repositories. If your runner labels differ, update the `runs-on` values in the central reusable workflows to match your organization.

### 4. Create deployment environments in each consumer repository

Create these GitHub environments in **the consumer repository**, not in the pipeline repository:

- `release-candidate` — the build-and-publish job uses this environment. Add required reviewers if candidate creation needs approval.
- `qa` — the QA approval gate uses this environment. Configure required reviewers here.
- `production` — the production promotion job uses this environment. Configure its branch/deployment protection rules and reviewers. Optionally define the environment variable `PRODUCTION_URL`; the workflow uses it as the deployment URL.

Reusable workflows execute with the caller repository's environment and variables. The environments therefore control approvals and deployments for that consumer, and the deployment history appears in that consumer repository. Configure them separately in every consumer repo (or standardize via organization processes).

## Add application projects to discovery

The discovery step currently recognizes .NET project files (`.csproj`, `.fsproj`, `.vbproj`) and React applications identified by a `package.json` with React dependencies or a `react-scripts` script. Applications must explicitly opt in:

For a .NET project, add this property to a `PropertyGroup`:

```xml
<PropertyGroup>
  <TargetFramework>net8.0</TargetFramework>
  <cicd>true</cicd>
</PropertyGroup>
```

For a React application, add a boolean property to its `package.json`:

```json
{
  "name": "web-app",
  "cicd": true,
  "dependencies": {
    "react": "^18.0.0",
    "react-dom": "^18.0.0"
  }
}
```

Set `cicd` to `false` to exclude an otherwise discoverable app. An app-level `Dockerfile` is detected automatically. The current build workflow installs Node packages with pnpm, builds/tests Node and .NET projects where scripts or project types support it, and locally builds detected Dockerfiles during validation.

## Install caller workflows

Copy the appropriate example from [`examples/consumer-workflows`](examples/consumer-workflows) into the consumer repository's `.github/workflows/` directory. Keep the example filename for validation, because source-run and baseline lookup expect `.github/workflows/validate-changed-applications.yml`.

The basic validation caller looks like this:

```yaml
name: Validation — Validate changed applications
run-name: "Integrated branch validation: ${{ github.ref_name }}"

on:
  workflow_dispatch:
  push:
    branches-ignore: [main]
  pull_request:
    branches-ignore: [main]

permissions:
  actions: write
  contents: read

jobs:
  validate:
    uses: synapptech-devops/pipelines/.github/workflows/validate-changed-applications.yml@main
    with:
      pipeline_ref: main
    secrets:
      PIPELINE_TOKEN: ${{ secrets.PIPELINE_TOKEN }}
```

For a public pipeline repository, the `PIPELINE_TOKEN` secret mapping can be omitted. For a private pipeline repository, create the secret in the consumer repository (or make it available through an organization secret) and retain the mapping. Copying the examples is a one-time setup; later pipeline implementation changes are made centrally.

### Available caller examples

| Example file                                  | Purpose                                                                                                              | Caller inputs                                                   |
| --------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| `validate-changed-applications.yml`           | Discover, validate, and build applications affected by a push or pull request; also supports manual full validation. | None                                                            |
| `build-affected-applications-manually.yml`    | Rebuild applications using manifests from an earlier validation run.                                                 | `source_sha`, `discovery_run_id`, optional `publish_containers` |
| `create-release-candidate-manually.yml`       | Build and publish a candidate for one app.                                                                           | `app_id`, `ref`, `bump`, optional `initial_version`             |
| `create-release-candidates-from-main.yml`     | Create candidates for apps changed since their individual previous candidate.                                        | `commit`                                                        |
| `promote-release-candidate-to-production.yml` | QA-gate, tag, and promote an existing candidate.                                                                     | `rc_tag`                                                        |
| `publish-development-artifacts.yml`           | Rebuild and publish dev-test artifacts from an earlier validation run.                                               | `source_run_id`                                                 |
| `generate-environment-manifest.yml`           | Update the environment manifest after candidate or production workflows complete; also supports manual runs.         | None                                                            |

The release workflow uses the `app_id` from a discovery manifest. Use the generated workflow summary or `discovery-manifest.json` artifact to find that ID. For manual rebuild and development-artifact workflows, use the run ID and source commit SHA from the validation run you want to rebuild.

The environment-manifest caller listens for workflows named `Generate Release Candidate Artifacts`, `Release — Create a candidate manually`, and `Promote Release Candidate to Production`. If you change those caller workflow names, update the `workflow_run.workflows` list in `generate-environment-manifest.yml` as well. The validation caller's `run-name` prefix is also used to locate successful baselines and should remain `Integrated branch validation:`.

## Run and operate the pipelines

1. Merge the caller workflow and opt-in project metadata to the consumer repository's default branch.
2. Open **Actions** in that consumer repository and run **Validation — Validate changed applications**, or push a branch/open a PR. Review the discovery summary and generated artifacts.
3. For manual rebuilds or publishing, select the corresponding caller workflow and provide the run ID, source SHA, app ID, ref, or tag requested by its inputs.
4. Candidate creation builds and tests the app before publishing a GitHub Release artifact and tag to the consumer repository. The `release-candidate` environment is applied to the build job.
5. After QA has signed off, run the promotion workflow with the RC tag. It checks the candidate is reachable from `main`, waits for the `qa` environment gate, then applies the `production` environment gate and promotes the tested artifact without rebuilding it.
6. The environment-manifest caller updates the `environment-manifest.json` release asset after candidate creation or promotion completes successfully.

Release tags, GitHub Releases, container images, and deployment records belong to the consumer repository, since that is the repository context in which the reusable workflow runs.

## Updating the shared pipeline

The examples reference `@main` and set `pipeline_ref: main`. This is the simplest centrally managed model: merge a change to this repository's `main`, and consuming repositories pick it up on their next workflow run without changes to their caller files.

For staged releases, update the caller's reusable-workflow ref and `pipeline_ref` together. For example, use `@v1` and `pipeline_ref: v1` only after a `v1` ref exists in this repository. Two release flows call the candidate-builder reusable workflow internally using a central `@main` reference; before pinning a release, update those internal references to the same release ref too. A commit SHA can be used for immutable workflow references, but all internal reusable-workflow references and `pipeline_ref` must identify the same revision.

## Troubleshooting

- **Reusable workflow cannot be accessed:** check the central repo's Actions access policy, the consumer's Actions policy, and that the workflow exists under `.github/workflows` on the referenced branch/tag.
- **Pipeline checkout returns 404 or authentication failure:** for a private central repository, verify `PIPELINE_TOKEN` is available to the caller and has read access. Also confirm the Actions access policy allows this consumer.
- **No applications found:** ensure the project type is supported and add `cicd: true` in the project file or package manifest. Check the workflow summary for invalid settings.
- **No runner matches:** confirm self-hosted runner labels and availability, including the `windows`/`linux` matrix labels and Windows/Linux requirements above.
- **Promotion is blocked:** check the consumer repository's `qa` and `production` environment reviewers, branch restrictions, and any pending approvals.
- **Environment-manifest workflow does not run:** check the completed workflow name matches one of its configured `workflow_run.workflows` entries and that the run succeeded.
