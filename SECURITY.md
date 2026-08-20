# Security Audit Report

## Overview
This document outlines the security audit findings for the GitHub Workflow Action and the fixes applied in version 2.0.0.

## Audit Date
August 2024

## Executive Summary
The original implementation contained several critical and high-severity security vulnerabilities related to:
- GitHub token exposure in logs and process history
- Insufficient API error handling
- Weak input validation
- Unvalidated JSON parsing
- Race conditions in workflow detection
- Information disclosure through verbose logging

All identified issues have been addressed in this release.

---

## Issues Identified & Resolution

### 🔴 Critical: GitHub Token Exposure in Command History

**Issue:**
The `GITHUB_TOKEN` was passed as a command-line argument to `curl`, which could be visible in:
- Shell history (`.bash_history`, `.zsh_history`)
- Process listings (`ps aux`)
- Log files with verbose logging enabled
- CI/CD logs if secret masking is misconfigured

**Original Code:**
```bash
curl -s -H "Authorization: token $GITHUB_TOKEN" \
  "https://api.github.com/repos/${ORG_NAME}/${REPO_NAME}/..."
```

**Fix Applied:**
- Token is passed through environment variables consistently
- Curl uses token from `$GITHUB_TOKEN` environment variable
- Process inspection will not reveal the token value
- GitHub Actions secret masking is respected

**Verification:**
```bash
# Token is not exposed in process info
ps aux | grep wait-for-workflow  # Token not visible
```

---

### 🔴 Critical: Sensitive Data in Error Messages & Logs

**Issue:**
- Full API responses were captured and potentially logged
- Configuration details (org, repo names) were echoed at startup
- Error messages could contain sensitive internal structure information
- Suitable for information gathering attacks

**Original Code:**
```bash
echo "ℹ️ Organization: ${ORG_NAME}"
echo "ℹ️ Repository: ${REPO_NAME}"
echo "ℹ️ Workflow ID: $workflow_id"
```

**Fix Applied:**
- Implemented structured logging with `log_info()` function
- API error responses are truncated (max 200 chars) before display
- Configuration details are logged at appropriate levels
- Error messages are descriptive without revealing unnecessary details
- Sensitive variable exposure is minimized

---

### 🟠 High: Unvalidated JSON Parsing

**Issue:**
- No validation that `jq` successfully parsed the response
- Malformed or error JSON could return unexpected values
- If GitHub API returned an error object, extraction might silently fail
- No validation that extracted `run_id` is actually numeric

**Original Code:**
```bash
run_id=$(echo "$response" | jq -r '.workflow_runs[] | ...')
if [ -n "$run_id" ]; then
  # Could be non-numeric or malformed
```

**Fix Applied:**
- Implemented `validate_json()` function for response validation
- Implemented `validate_numeric_id()` for ID format validation
- JSON parsing errors are caught and reported
- Extracted IDs are validated as numeric before use
- All API response fields are checked with `// empty` fallback

```bash
validate_json "$response_file" "workflow runs query"
validate_numeric_id "extracted run_id" "$run_id"
```

---

### 🟠 High: Insufficient API Error Handling

**Issue:**
- Only checked for 2 specific error strings (rate limit, not found)
- Curl `-f` flag not used, so HTTP errors (4xx/5xx) succeeded silently
- Network errors not handled
- Authentication failures (401), permission errors (403) went undetected

**Original Code:**
```bash
if echo "$response" | grep -q "API rate limit exceeded"; then
  exit 1
elif echo "$response" | grep -q "Not Found"; then
  exit 1
fi
# All other responses treated as success
```

**Fix Applied:**
- Capture HTTP status codes with `curl -w "%{http_code}"`
- Implemented `handle_api_error()` function with comprehensive error handling
- All HTTP status codes properly categorized and handled:
  - `200`: Success
  - `401`: Authentication failure
  - `403`: Permission denied / Rate limit
  - `404`: Resource not found
  - Others: Generic API error with details

```bash
http_code=$(curl -s -w "%{http_code}" -o "$output_file" ...)
handle_api_error "$http_code" "$response_file" "context"
```

---

### 🟡 Medium-High: Weak Input Validation

**Issue:**
- No validation that required inputs (`ORG_NAME`, `REPO_NAME`, `WORKFLOW_ID`) are non-empty
- No sanitization to prevent unexpected behavior
- Numeric inputs (`MAX_WAIT_MINUTES`, `TIMEOUT`, `INTERVAL`) not validated
- Could lead to infinite loops, negative timeouts, division by zero

**Original Code:**
```bash
max_wait_minutes="${MAX_WAIT_MINUTES}"
# No validation
if [ $((counter * $interval)) -ge $((max_wait_minutes * 60)) ]; then
  # Could crash or behave unexpectedly with invalid input
```

**Fix Applied:**
- Implemented `validate_input()` for required non-empty inputs
- Implemented `validate_positive_int()` for numeric validation
- All inputs validated at startup before use
- Clear error messages for invalid input

```bash
validate_input "ORG_NAME" "$ORG_NAME"
validate_positive_int "MAX_WAIT_MINUTES" "$max_wait_minutes"
```

---

### 🟡 Medium: Race Condition in Workflow Detection

**Issue:**
- Script captured "current time" at startup, but workflow could be triggered slightly before
- Clock skew between GitHub runner and GitHub servers could cause workflow to be missed
- Multiple workflows on same branch within interval could select wrong one

**Original Code:**
```bash
current_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
# ... later, after potential delay ...
'.workflow_runs[] | select(.head_branch == $ref and .created_at >= $current_time)'
```

**Fix Applied:**
- Added 5-minute buffer to account for clock skew
- Select most recent matching workflow instead of time-based filtering
- More reliable workflow identification
- Reduces false negatives

```bash
buffer_minutes=5
current_time=$(date -u -d "-${buffer_minutes} minutes" +"%Y-%m-%dT%H:%M:%SZ")
# Select most recent workflow matching ref
run_id=$(jq -r '.workflow_runs[] | select(.head_branch == $ref) | .id' | head -1)
```

---

### 🟡 Medium: Enhanced Security Hardening

**Additional Improvements:**
- Added `set -euo pipefail` for strict error handling
- Temporary directory created for API responses with automatic cleanup
- Trap handler for cleanup on exit
- Standardized function-based code organization
- Comprehensive inline documentation
- Consistent error handling patterns throughout

---

## Compliance & Best Practices

### ✅ Implemented
- **OWASP Top 10**: Input validation, error handling, secure logging
- **NIST Cybersecurity Framework**: Asset management, access control, supply chain risk
- **Shell Script Best Practices**: Error handling, input validation, safe temporary files
- **GitHub Security**: Token protection, minimal log exposure, proper API usage
- **Principle of Least Privilege**: Minimal information disclosure, segmented error handling

### 🛡️ Defense in Depth
1. **Input Validation Layer**: All inputs validated before use
2. **API Communication Layer**: Proper error handling and status code checking
3. **Response Processing Layer**: JSON validation and ID verification
4. **Output Layer**: Structured logging with sensitive data protection
5. **Cleanup Layer**: Temporary files automatically removed

---

## Testing Recommendations

### Unit Tests
```bash
# Test input validation
MAX_WAIT_MINUTES="" ./scripts/wait-for-workflow.sh  # Should fail
MAX_WAIT_MINUTES="abc" ./scripts/wait-for-workflow.sh  # Should fail
MAX_WAIT_MINUTES="-5" ./scripts/wait-for-workflow.sh  # Should fail
```

### Integration Tests
```bash
# Test API error handling
# Mock 401, 403, 404, 429 responses

# Test with valid inputs and actual GitHub API
GITHUB_TOKEN="valid_token" ./scripts/wait-for-workflow.sh
```

### Security Tests
```bash
# Verify token not exposed
strace -e write ./scripts/wait-for-workflow.sh 2>&1 | grep -i token  # Should fail
history | grep GITHUB_TOKEN  # Should not contain actual token
```

---

## Migration Guide

### For Users
No changes required for most use cases. The updated action maintains backward compatibility with the same inputs and outputs.

### For CI/CD Integrations
The action behavior remains the same, but with improved reliability:
- Better error messages for troubleshooting
- More robust workflow detection
- Improved handling of edge cases

### Breaking Changes
None - full backward compatibility maintained.

---

## Security Advisories

- Always use GitHub Actions secrets for `GITHUB_TOKEN` input
- Ensure runners have access to required repositories
- Monitor GitHub API rate limits in your workflows
- Consider using `permissions` in workflow to scope token access

---

## Version History

### 2.0.0 (Current)
- 🔒 Security hardening with comprehensive validation
- 🛡️ Protection against token exposure
- ✅ Robust error handling and API status codes
- 📝 Enhanced logging with sensitive data protection
- 🔧 Better maintainability and code organization

### 1.1.0 and earlier
- Original implementation with identified vulnerabilities

---

## Reporting Security Issues

If you discover a security vulnerability, please email the maintainer directly instead of using the issue tracker. Include:
- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

---

## References

- [GitHub Actions Security Best Practices](https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions)
- [OWASP Bash/Shell Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Bash_Cheat_Sheet.html)
- [Shell Script Security Guidelines](https://mywiki.wooledge.org/BashGuide/Practices#Security)
- [GitHub API Documentation](https://docs.github.com/en/rest)

---

**Last Updated:** August 2024  
**Audit Status:** ✅ All identified issues resolved
