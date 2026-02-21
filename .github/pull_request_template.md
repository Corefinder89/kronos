## Pull Request Description

### What does this PR do?
<!-- A clear and concise description of what this PR accomplishes -->

### Type of Change
<!-- Mark the relevant option with an "x" -->
- [ ] 🐛 Bug fix (non-breaking change which fixes an issue)
- [ ] ✨ New feature (non-breaking change which adds functionality)
- [ ] 💥 Breaking change (fix or feature that would cause existing functionality to not work as expected)
- [ ] 📚 Documentation update
- [ ] 🧹 Code cleanup/refactoring
- [ ] 🔧 Configuration change
- [ ] 🚀 Performance improvement

### Related Issues
<!-- Link to any related issues using #issue_number -->
Fixes #
Closes #
Related to #

---

## Testing & Validation

### Testing Performed
<!-- Describe the testing you've done -->
- [ ] Tested locally with `scripts/healthcheck.sh`
- [ ] Verified with `scripts/tests/grid_test.py`
- [ ] Tested deployment with `scripts/dropletsetup.sh`
- [ ] Tested cleanup with `scripts/destroy.sh`
- [ ] Manual testing performed: _(describe)_

### Test Environment
- **OS**: 
- **Docker Version**: 
- **doctl Version**: 
- **Node Count**: 
- **DigitalOcean Region**: 

### Health Check Results
<!-- Include output from scripts/healthcheck.sh if relevant -->
```
[Paste healthcheck output here]
```

---

## Code Quality

### Code Review Checklist
<!-- For the reviewer -->
- [ ] Code follows existing patterns and conventions
- [ ] Shell scripts use proper error handling (`set -euo pipefail`)
- [ ] Functions have clear purposes and documentation
- [ ] Security considerations have been addressed
- [ ] No sensitive data is hardcoded or committed

### Documentation Updates
- [ ] README.md updated (if needed)
- [ ] CODEGUIDANCE.md updated (if needed)
- [ ] Code comments added/updated
- [ ] No documentation changes needed

---

## Security & Infrastructure

### Security Impact
- [ ] No security implications
- [ ] Changes reviewed for security concerns
- [ ] Credentials handling is secure
- [ ] Network security maintained
- [ ] SSH configurations are safe

### Infrastructure Impact
- [ ] No infrastructure changes
- [ ] Changes tested on DigitalOcean
- [ ] Resource usage considered
- [ ] Cost implications understood
- [ ] Breaking changes documented

---

## Deployment

### Deployment Notes
<!-- Any special deployment instructions or considerations -->

### Rollback Plan
<!-- How to rollback if issues are found after deployment -->

### Post-Deployment Verification
<!-- Steps to verify the deployment was successful -->
- [ ] Run `scripts/healthcheck.sh --fix`
- [ ] Execute `scripts/tests/grid_test.py --hub <manager-ip> --browser both`
- [ ] Verify Grid console accessibility
- [ ] Check service scaling behavior

---

## Additional Notes
<!-- Any additional information that reviewers should know -->

### Breaking Changes
<!-- If this is a breaking change, describe what users need to do -->

### Migration Guide
<!-- If users need to migrate configurations or data -->

---

## Reviewer Notes
<!-- For code owners and reviewers -->

**Code Owner Review:** @corefinder89
**Security Review:** (if applicable)
**Documentation Review:** (if applicable)

### Review Checklist for Code Owners
- [ ] Functionality works as described
- [ ] Code quality meets project standards
- [ ] Security implications considered
- [ ] Documentation is adequate
- [ ] Testing is sufficient
- [ ] No regression risks identified