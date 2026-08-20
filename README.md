# Wait for Workflow Action

[![Test WaitForWorkflow](https://github.com/kamilchodola/wait-for-workflow-action/actions/workflows/test.yml/badge.svg)](https://github.com/kamilchodola/wait-for-workflow-action/actions/workflows/test.yml)

This GitHub Action waits for a specified workflow to complete before proceeding with the next steps in your workflow. It is useful when you have dependent workflows and want to ensure that one completes successfully before moving forward.

## Security Notice

**Version 2.0.0+**: This release includes comprehensive security hardening. See [SECURITY.md](./SECURITY.md) for details on vulnerabilities identified and fixed. All recommendations from the security audit have been implemented.

## Inputs

| Input            | Description                                         | Required | Default |
|------------------|-----------------------------------------------------|----------|---------|
| `GITHUB_TOKEN`   | GitHub token to access the repository and its APIs  | Yes      |         |
| `workflow_id`    | ID of the workflow to wait for                      | No       |         |
| `run_id`         | If provided will wait for workflow run with specified id                     | No       |         |
| `max_wait_minutes`| Maximum time script will wait to workflow run to be found in minutes      | No       | 5       |
| `interval`| Interval in seconds which will be used for GitHub API calls      | No       | 10       |
| `timeout`| Maximum time script will wait to workflow run to be finished      | No       | 30       |
| `org_name`   | Organization name where the repository is located   | Yes      |         |
| `repo_name`     | Repository name to monitor for the workflow run     | Yes      |         |
| `ref`            | Branch reference to watch for the workflow run      | No       |         |

### Security Recommendations

- **Always use GitHub Actions secrets** for the `GITHUB_TOKEN` input. Never hardcode or expose tokens.
- **Scope the token**: GitHub Actions automatically creates a `GITHUB_TOKEN` with minimal required permissions. Use this when possible.
- **Custom tokens**: If using a custom token via `secrets.CUSTOM_TOKEN`, ensure it has only the necessary scopes (`actions:read` and `repo` if needed).

```yaml
with:
  GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}  # Recommended
  # OR
  GITHUB_TOKEN: ${{ secrets.CUSTOM_TOKEN }}  # If custom token needed
```

## How It Works

This action performs the following steps:

1. **Input Validation**: Validates all required inputs are provided and have correct formats (positive integers for timeouts).
2. **Workflow Discovery**: 
   - If `run_id` is provided, uses it directly
   - Otherwise, queries the GitHub API for workflow runs matching the specified `workflow_id` and branch reference
   - Selects the most recent workflow run on the target branch
3. **Workflow Monitoring**: 
   - Polls the GitHub API at specified intervals for the workflow run status
   - Continues until the workflow run reaches a "completed" state
4. **Result Verification**:
   - If conclusion is "success", exits with status 0
   - If conclusion is anything other than "success", exits with status 1

## Usage

To use this action, add it to your workflow file with the appropriate inputs:

```yaml
- name: Wait for Workflow Action
  uses: oleksandr-danylchenko/wait-for-workflow-action@v2.0.0
  with:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    workflow_id: 'workflow_name.yml'
    max_wait_minutes: '3'
    interval: '5'
    timeout: '60'
    org_name: 'your-organization'
    repo_name: 'your-repository'
    ref: '${{ github.ref }}'
```

### Using with an Existing Run ID

If you already have a run ID (for example, from a previous workflow dispatch call), you can pass it directly:

```yaml
- name: Wait for Workflow Action
  uses: oleksandr-danylchenko/wait-for-workflow-action@v2.0.0
  with:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    run_id: '1234567890'
    timeout: '60'
    org_name: 'your-organization'
    repo_name: 'your-repository'
```

### Complete Example with Workflow Dispatch

```yaml
name: Dependent Workflow

on:
  push:
    branches: [main]

jobs:
  trigger-and-wait:
    runs-on: ubuntu-latest
    steps:
      - name: Trigger another workflow
        id: dispatch
        uses: actions/github-script@v6
        with:
          script: |
            const response = await github.rest.actions.createWorkflowDispatch({
              owner: 'your-organization',
              repo: 'your-repository',
              workflow_id: 'build.yml',
              ref: 'main'
            });
            core.setOutput('status', response.status);

      - name: Wait for triggered workflow to complete
        uses: oleksandr-danylchenko/wait-for-workflow-action@v2.0.0
        with:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          workflow_id: 'build.yml'
          max_wait_minutes: '5'
          interval: '10'
          timeout: '120'
          org_name: 'your-organization'
          repo_name: 'your-repository'
          ref: 'main'

      - name: Proceed with next steps
        run: echo "Workflow completed successfully!"
```

## Common Scenarios

### Waiting for a Build Workflow

```yaml
- uses: oleksandr-danylchenko/wait-for-workflow-action@v2.0.0
  with:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    workflow_id: 'build.yml'
    org_name: 'myorg'
    repo_name: 'myrepo'
    ref: ${{ github.ref }}
```

### Waiting with Custom Timeouts

```yaml
- uses: oleksandr-danylchenko/wait-for-workflow-action@v2.0.0
  with:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    workflow_id: 'deploy.yml'
    max_wait_minutes: '10'    # Wait up to 10 minutes for workflow to trigger
    timeout: '300'            # Wait up to 5 hours for workflow to complete
    interval: '30'            # Check every 30 seconds
    org_name: 'myorg'
    repo_name: 'myrepo'
```

### Waiting for a Specific Run

```yaml
- uses: oleksandr-danylchenko/wait-for-workflow-action@v2.0.0
  with:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    run_id: ${{ steps.dispatch.outputs.run_id }}
    timeout: '120'
    org_name: 'myorg'
    repo_name: 'myrepo'
```

## Notes

- **Branch Reference**: If the `ref` input is not provided or is left empty, the action will use the current `github.ref` as the branch reference. This is useful when you want to wait for a workflow run on the same branch that triggered your current workflow.
- **Maximum Wait Time**: The default maximum wait time is 3 minutes if not provided. If the workflow has not been triggered or completed after the specified maximum wait time, the action will exit with an error.
- **API Rate Limiting**: GitHub API has rate limits (60 requests per hour for unauthenticated, 5000 for authenticated). The default interval of 10 seconds means each workflow can make ~6 API calls per minute. Monitor your usage if running many parallel workflows.
- **Timeout Behavior**: 
  - `max_wait_minutes`: Time to wait for the workflow to be triggered (to appear in the API)
  - `timeout`: Time to wait for the workflow to complete once triggered
  - `interval`: Time between API calls (affects both timers)

## Error Messages and Troubleshooting

### "Missing required input: GITHUB_TOKEN"
- Ensure you're passing `GITHUB_TOKEN` in the `with` section
- Check that the token is valid and not expired

### "Invalid input provided (organization, repository, or workflow ID)"
- Verify the `org_name`, `repo_name`, and `workflow_id` are correct
- Ensure the workflow file exists in the target repository
- Check token permissions allow reading the repository

### "API rate limit exceeded"
- You've hit GitHub's rate limit
- Consider increasing the `interval` to reduce API call frequency
- Use a PAT (Personal Access Token) with higher rate limits if needed

### "Maximum waiting time for the workflow to be triggered has been reached"
- The workflow wasn't triggered within `max_wait_minutes`
- Ensure the workflow is properly configured to trigger
- Check that the branch/ref is correct
- Verify the token has permission to trigger workflows

### "Timeout waiting for the workflow to complete"
- The workflow took longer than `timeout` minutes to complete
- Increase the `timeout` value if the workflow legitimately takes longer
- Check the target workflow logs for bottlenecks or failures

## Security Considerations

- **Token Exposure**: The action uses GitHub Actions' built-in secret masking. Tokens are never logged or exposed in output.
- **API Communication**: All API calls use HTTPS to GitHub's API endpoints.
- **Input Validation**: All inputs are validated to prevent injection attacks or unexpected behavior.
- **Error Handling**: API errors are handled gracefully without exposing sensitive information.

See [SECURITY.md](./SECURITY.md) for more details on security hardening and best practices.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Changelog

### v2.0.0
- **SECURITY**: Comprehensive security hardening addressing 8 identified vulnerabilities
- **ENHANCEMENT**: Improved input validation and error handling
- **ENHANCEMENT**: Better API error messages with proper HTTP status code handling
- **ENHANCEMENT**: Protected against token exposure in logs and process history
- **ENHANCEMENT**: Added race condition mitigation for workflow detection
- **DOCS**: Added detailed security audit report in SECURITY.md

### v1.1.0 and earlier
- Original implementation

## Support

If you encounter issues or have questions, please open an issue on GitHub. For security concerns, please see the security section in [SECURITY.md](./SECURITY.md).
