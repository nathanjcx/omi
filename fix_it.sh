export COMMIT_MSG=$(cat << 'INNER_EOF'
fix: refactor and combine embedding visualization functions

Failure-Class: none
INNER_EOF
)
git commit --amend -m "$COMMIT_MSG"
