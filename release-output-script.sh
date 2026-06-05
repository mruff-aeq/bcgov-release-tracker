echo ""
echo "bcgov/lear"
echo ""
~/Desktop/release-watch.sh 2 business-bn-cd.yml bcgov/lear test-release
echo ""
echo "bcgov/business-filings-ui"
echo ""
~/Desktop/release-watch.sh 2 cd.yml bcgov/business-filings-ui test-release
echo ""
echo "bcgov/business-create-ui"
echo ""
~/Desktop/release-watch.sh 2 cd.yml bcgov/business-create-ui test-release
echo ""
echo "bcgov/business-edit-ui"
echo ""
~/Desktop/release-watch.sh 2 cd.yml bcgov/business-edit-ui test-release
echo ""
echo "bcgov/business-dashboard-ui"
echo ""
~/Desktop/release-watch.sh 2 cd.yml bcgov/business-dashboard-ui test-release
echo ""
echo "bcgov/business-ui - checking web/business-registry-dashboard"
echo ""
~/Desktop/release-watch.sh 2 business-registry-ui-cd.yaml bcgov/business-ui test-release --in-dirs=web/business-registry-dashboard

echo "business-edit-ui:       $(curl -fsSL https://raw.githubusercontent.com/bcgov/business-edit-ui/main/package.json      | jq -r .version)"
echo "business-filings-ui:    $(curl -fsSL https://raw.githubusercontent.com/bcgov/business-filings-ui/main/package.json   | jq -r .version)"
echo "business-create-ui:     $(curl -fsSL https://raw.githubusercontent.com/bcgov/business-create-ui/main/package.json    | jq -r .version)"
echo "business-dashboard-ui:  $(curl -fsSL https://raw.githubusercontent.com/bcgov/business-dashboard-ui/main/package.json | jq -r .version)"
echo "business-registry-dashboard:  $(curl -fsSL https://raw.githubusercontent.com/bcgov/business-ui/refs/heads/main/web/business-registry-dashboard/package.json | jq -r .version)"
echo "legal-api:  $(curl -fsSL https://raw.githubusercontent.com/bcgov/lear/refs/heads/main/legal-api/src/legal_api/version.py | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')" 


