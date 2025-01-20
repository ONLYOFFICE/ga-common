#!/usr/bin/env bash

set -e  # Exit immediately if a command exits with a non-zero status

cd "${GITHUB_WORKSPACE}/snyk/"

ORG="ONLYOFFICE"

npm install 
npm run start scan-org -- --org ${ORG} | tee -a ./result.log

EXIT_CODE=0

# Define symbols as variables for readability
ARROW_DOWN="\u2193"
ARROW_UP="\u2191"

# Arrays to store issues by severity
declare -a CRITICAL_ISSUES
declare -a WARNING_ISSUES
declare -a CRITICAL_LINKS

log_issue() {
  local issue_name=$1
  local severity=$2
  local level=$3
  local issue_log=$(egrep -i "The rule $issue_name" ./result.log)
  
  if [[ "$issue_log" ]]; then
    local count=$(echo "$issue_log" | wc -l)
    local issue_output="Issue name: **${issue_name}**\nStatus: **exist**\nCount: ${count}\n"

    if [[ "$severity" == "red" ]]; then
      CRITICAL_ISSUES+=("$issue_output")
      EXIT_CODE=1
      # Extract links for critical issues
      local links=$(echo "$issue_log" | grep -oP '(?<=The rule '$issue_name' triggered for ).*')
      CRITICAL_LINKS+=("$links")
    else
      WARNING_ISSUES+=("$issue_output")
    fi
  fi
}

echo -e "### SNYK SCANNER RESULT **${ARROW_DOWN}**" >> $GITHUB_STEP_SUMMARY
echo "" >> $GITHUB_STEP_SUMMARY
echo -e "#### SECURITY ISSUES:**${ARROW_DOWN}**" >> $GITHUB_STEP_SUMMARY

log_issue "CMD_EXEC" "red" "CRYCICAL"
log_issue "CODE_INJECT" "red" "CRYCICAL"
log_issue "PWN_REQUEST" "yellow" "WARNING"
log_issue "UNSAFE_INPUT_ASSIGN" "yellow" "WARNING"
log_issue "WORKFLOW_RUN" "yellow" "WARNING"
log_issue "REPOJACKABLE" "yellow" "WARNING"
log_issue "UNPINNED_ACTION" "yellow" "WARNING"

# Output critical issues
if [[ ${#CRITICAL_ISSUES[@]} -ne 0 ]]; then
  echo 'LEVEL: $${\color{red}CRYTICAL}$$' >> $GITHUB_STEP_SUMMARY  # Red color for CRITICAL
  echo "------------------" >> $GITHUB_STEP_SUMMARY
  for issue in "${CRITICAL_ISSUES[@]}"; do
    echo -e "$issue" >> $GITHUB_STEP_SUMMARY
    echo "" >> $GITHUB_STEP_SUMMARY
  done
  echo "ISSUES LINKS:" >> $GITHUB_STEP_SUMMARY
  for link in "${CRITICAL_LINKS[@]}"; do
    echo -e "$link" >> $GITHUB_STEP_SUMMARY
  done
fi

# Output warning issues
if [[ ${#WARNING_ISSUES[@]} -ne 0 ]]; then
  echo "LEVEL: WARNING" >> $GITHUB_STEP_SUMMARY
  echo "------------------" >> $GITHUB_STEP_SUMMARY
  for issue in "${WARNING_ISSUES[@]}"; do
    echo -e "$issue" >> $GITHUB_STEP_SUMMARY
    echo "" >> $GITHUB_STEP_SUMMARY
  done
fi

if [[ $EXIT_CODE -eq 0 ]]; then
  echo "No critical issues found. All checks passed successfully." >> $GITHUB_STEP_SUMMARY
else
  echo "Critical issues found. Please review action artifacts above and take necessary actions." >> $GITHUB_STEP_SUMMARY
  echo "Take a look at the description of the vulnerabilities found:" >> $GITHUB_STEP_SUMMARY
  echo -e "https://github.com/snyk-labs/github-actions-scanner?tab=readme-ov-file#rules" >> $GITHUB_STEP_SUMMARY
fi

exit $EXIT_CODE
