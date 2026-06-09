# bcgov/lear
echo "<!-- bcgov/lear -->"
echo "<h2>"
echo "bcgov/lear"
echo "</h2>"
echo "<pre>"
./pre-release-watch.sh 2 business-bn-cd.yml bcgov/lear test-release --html
echo "</pre>"
echo "<hr>"

# bcgov/business-filings-ui
echo "<!-- bcgov/business-filings-ui -->"
echo "<h2>"
echo "bcgov/business-filings-ui"
echo "</h2>"
echo "<pre>"
./per-release-watch.sh 2 cd.yml bcgov/business-filings-ui test-release --html
echo "</pre>"
echo "<hr>"

# bcgov/business-create-ui
echo "<!-- bcgov/business-create-ui -->"
echo "<h2>"
echo "bcgov/business-create-ui"
echo "</h2>"
echo "<pre>"
./pre-release-watch.sh 2 cd.yml bcgov/business-create-ui test-release --html
echo "</pre>"
echo "<hr>"

# bcgov/business-edit-ui
echo "<!-- bcgov/business-edit-ui -->"
echo "<h2>"
echo "bcgov/business-edit-ui"
echo "</h2>"
echo "<pre>"
./pre-release-watch.sh 2 cd.yml bcgov/business-edit-ui test-release --html
echo "</pre>"
echo "<hr>"

# bcgov/business-dashboard-ui
echo "<!-- bcgov/business-dashboard-ui -->"
echo "<h2>"
echo "bcgov/business-dashboard-ui"
echo "</h2>"
echo "<pre>"
./pre-release-watch.sh 2 cd.yml bcgov/business-dashboard-ui test-release --html
echo "</pre>"
echo "<hr>"

# bcgov/business-ui (web/business-registry-dashboard)
echo "<!-- bcgov/business-ui web/business-registry-dashboard -->"
echo "<h2>"
echo "bcgov/business-ui (web/business-registry-dashboard)"
echo "</h2>"
echo "<pre>"
./pre-release-watch.sh 2 business-registry-ui-cd.yaml bcgov/business-ui test-release --in-dirs=web/business-registry-dashboard --html
echo "</pre>"
echo "<hr>"

# Repo Versions
echo "<!-- repo versions -->"
echo "<h2>"
echo "Repo Versions"
echo "</h2>"
echo "<pre>"
echo "business-edit-ui:       $(curl -fsSL https://raw.githubusercontent.com/bcgov/business-edit-ui/main/package.json      | jq -r .version)"
echo "business-filings-ui:    $(curl -fsSL https://raw.githubusercontent.com/bcgov/business-filings-ui/main/package.json   | jq -r .version)"
echo "business-create-ui:     $(curl -fsSL https://raw.githubusercontent.com/bcgov/business-create-ui/main/package.json    | jq -r .version)"
echo "business-dashboard-ui:  $(curl -fsSL https://raw.githubusercontent.com/bcgov/business-dashboard-ui/main/package.json | jq -r .version)"
echo "business-registry-dashboard:  $(curl -fsSL https://raw.githubusercontent.com/bcgov/business-ui/refs/heads/main/web/business-registry-dashboard/package.json | jq -r .version)"
echo "legal-api:  $(curl -fsSL https://raw.githubusercontent.com/bcgov/lear/refs/heads/main/legal-api/src/legal_api/version.py | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
echo "</pre>"
echo "<hr>"
