# bcgov-release-tracker

> A set of bash utilities to track GitHub Actions deployments and generate pending release candidate lists across BC Gov repositories.

## Overview

This toolkit consists of two scripts that work together to track GitHub Action deployments, identify where code is deployed (dev, test, or prod), and generate lists of pending release candidates (merged Pull Requests).

---

### 🚀 Quick Start & Usage

To get started, clone the repository to your local machine, navigate into the directory, and run the wrapper script to generate your full report:

```bash
# 1. Clone the repository
git clone https://github.com/mruff-aeq/bcgov-release-tracker.git

# 2. Navigate into the directory
cd bcgov-release-tracker

# 3. Make the scripts executable
chmod +x release-watch.sh release-output-script.sh

# 4. Run the script to output deployment tables, PRs pending release, and current versions
./release-output-script.sh
```

### 🛠 Prerequisites

To run these scripts, you must have the following installed on your machine:
* **GitHub CLI (`gh`)**: Must be installed and authenticated (`gh auth login`) with access to the target repositories.
* **`jq`**: A lightweight command-line JSON processor used to read version numbers.
* **`curl`**: Used to fetch files directly from GitHub.

---

### ⚙️ How It Works

#### 1. The Core Tool (`release-watch.sh`)
This is the heavy lifter. When executed, it talks to GitHub to figure out exactly what is going on with your deployments.
* **Deployment History**: It grabs the last few manual GitHub Action runs and reads their logs to determine exactly which environment (`dev`, `test`, `sandbox`, `prod`) the code was deployed to.
* **Release Candidates (`test-release`)**: If you pass the `test-release` flag, it finds the exact commit currently sitting in the `test` environment, and then prints a neat table of all Pull Requests that have been merged *after* that commit.
* **Monorepo Filtering (`--in-dirs`)**: It can check if a PR modified files in a specific directory (useful for monorepos like `business-ui`).
* **Output**: It generates both a terminal text table and a raw HTML table so you can easily copy and paste the release notes.

#### 2. The Wrapper Script (`release-output-script.sh`)
This script automates the core tool to give you a bird's-eye view of your entire project suite.
* It runs the core `release-watch.sh` tool sequentially across multiple BC Gov repositories (e.g., `lear`, `business-filings-ui`, `business-create-ui`, `business-edit-ui`, and `business-dashboard-ui`).
* After generating the release notes for all repositories, it uses `curl` and `jq` to fetch the live, current version numbers directly from the `package.json` and `version.py` files on GitHub's main branch.

---

### 🚀 Usage

To get a full report, simply run your wrapper script in the terminal:

```bash
# This will output deployment tables, PRs pending release, and current versions
./release-output-script.sh
```
If you want to use the core tool manually on a specific repository to see the last 2 runs and unreleased PRs, use:

```bash
./release-watch.sh 2 cd.yml bcgov/business-filings-ui test-release
```
<hr>

## Example Output
```html
bcgov/lear

RUN    ENV       RESULT   ACTOR            COMMIT    CREATED (UTC)         MESSAGE                       
------ -------   ------   ---------------- -------   --------------------- ------------------------------
#58    prod      success  mruff-aeq        8af6370   2026-06-04 19:03:53   33304 regenerate documents af 
#55    test      success  mruff-aeq        70df86f   2026-06-01 20:40:37   Merge pull request #4449 from 

test-release: merged PRs newer than the commit on test (#55 -> 70df86f, excluded)
TITLE                                      AUTHOR               PR      TICKET    Merged_Date  COMMIT   
------------------------------------------ -------------------- ------- -------   -----------  -------  
33671 fix completing party sync issue      @vysakh-menon-aot    #4458   #33671    2026-06-04   da645cd  
Feature pg8000 graceful shutdown           @panish16            #4457   NA        2026-06-04   2e8f852  
33304 regenerate documents after receivin  @vysakh-menon-aot    #4454   #33304    2026-06-04   8af6370  
Feature add pg8000 graceful shutdown on C  @panish16            #4453   NA        2026-06-03   85e0185  
33656 Add exclude business filter to mv_l  @argush3             #4452   #33656    2026-06-02   051fbc4  
33652 - Update Auto Pruning Logic for Fro  @Rajandeep98         #4451   #33652    2026-06-03   c6dddda  

<table>
  <tr><th>Title</th><th>Author</th><th>PR</th><th>Ticket</th><th>Merged_Date</th><th>Commit</th></tr>
  <tr><td>33671 fix completing party sync issue</td><td>@vysakh-menon-aot</td><td>#4458</td><td><a href="https://github.com/bcgov/entity/issues/33671">#33671</a></td><td>2026-06-04</td><td>da645cd</td></tr>
  <tr><td>Feature pg8000 graceful shutdown</td><td>@panish16</td><td>#4457</td><td>NA</td><td>2026-06-04</td><td>2e8f852</td></tr>
  <tr><td>33304 regenerate documents after receiving BN15</td><td>@vysakh-menon-aot</td><td>#4454</td><td><a href="https://github.com/bcgov/entity/issues/33304">#33304</a></td><td>2026-06-04</td><td>8af6370</td></tr>
  <tr><td>Feature add pg8000 graceful shutdown on Cloud Run scale-down</td><td>@panish16</td><td>#4453</td><td>NA</td><td>2026-06-03</td><td>85e0185</td></tr>
  <tr><td>33656 Add exclude business filter to mv_legacy_corps_data</td><td>@argush3</td><td>#4452</td><td><a href="https://github.com/bcgov/entity/issues/33656">#33656</a></td><td>2026-06-02</td><td>051fbc4</td></tr>
  <tr><td>33652 - Update Auto Pruning Logic for Frozen Corps</td><td>@Rajandeep98</td><td>#4451</td><td><a href="https://github.com/bcgov/entity/issues/33652">#33652</a></td><td>2026-06-03</td><td>c6dddda</td></tr>
</table>

bcgov/business-filings-ui

RUN    ENV       RESULT   ACTOR            COMMIT    CREATED (UTC)         MESSAGE                       
------ -------   ------   ---------------- -------   --------------------- ------------------------------
#1031  prod      success  mruff-aeq        e607fdd   2026-06-04 19:02:08   33571 - bump @bcrs-shared-com 
#1029  test      success  mruff-aeq        0a99f21   2026-06-01 20:46:32   33467 - require Latin-1 on ed 

test-release: merged PRs newer than the commit on test (#1029 -> 0a99f21, excluded)
TITLE                                      AUTHOR               PR      TICKET    Merged_Date  COMMIT   
------------------------------------------ -------------------- ------- -------   -----------  -------  
33571 - bump @bcrs-shared-components depe  @mruff-aeq           #810    #33571    2026-06-03   e607fdd  

<table>
  <tr><th>Title</th><th>Author</th><th>PR</th><th>Ticket</th><th>Merged_Date</th><th>Commit</th></tr>
  <tr><td>33571 - bump @bcrs-shared-components dependencies</td><td>@mruff-aeq</td><td>#810</td><td><a href="https://github.com/bcgov/entity/issues/33571">#33571</a></td><td>2026-06-03</td><td>e607fdd</td></tr>
</table>

bcgov/business-create-ui

RUN    ENV       RESULT   ACTOR            COMMIT    CREATED (UTC)         MESSAGE                       
------ -------   ------   ---------------- -------   --------------------- ------------------------------
#1057  prod      success  loneil           8c84b25   2026-05-28 20:32:03   Merge pull request #865 from  
#1056  test      success  loneil           8c84b25   2026-05-26 20:45:58   Merge pull request #865 from  

test-release: merged PRs newer than the commit on test (#1056 -> 8c84b25, excluded)
TITLE                                      AUTHOR               PR      TICKET    Merged_Date  COMMIT   
------------------------------------------ -------------------- ------- -------   -----------  -------  
32780 - Remove Completing Party from Inco  @mruff-aeq           #868    #32780    2026-06-04   7c34255  
33467_directors_require_latin1             @mruff-aeq           #867    #33467    2026-06-03   54f5d2a  

<table>
  <tr><th>Title</th><th>Author</th><th>PR</th><th>Ticket</th><th>Merged_Date</th><th>Commit</th></tr>
  <tr><td>32780 - Remove Completing Party from Incorporation Application</td><td>@mruff-aeq</td><td>#868</td><td><a href="https://github.com/bcgov/entity/issues/32780">#32780</a></td><td>2026-06-04</td><td>7c34255</td></tr>
  <tr><td>33467_directors_require_latin1</td><td>@mruff-aeq</td><td>#867</td><td><a href="https://github.com/bcgov/entity/issues/33467">#33467</a></td><td>2026-06-03</td><td>54f5d2a</td></tr>
</table>

bcgov/business-edit-ui

RUN    ENV       RESULT   ACTOR            COMMIT    CREATED (UTC)         MESSAGE                       
------ -------   ------   ---------------- -------   --------------------- ------------------------------
#957   prod      success  loneil           a117344   2026-05-28 20:31:56   33321 share rows style (#698) 
#955   test      success  loneil           0a006c6   2026-05-26 20:45:51   Merge pull request #697 from  

test-release: merged PRs newer than the commit on test (#955 -> 0a006c6, excluded)
TITLE                                      AUTHOR               PR      TICKET    Merged_Date  COMMIT   
------------------------------------------ -------------------- ------- -------   -----------  -------  
33467_directors_require_latin1             @mruff-aeq           #699    #33467    2026-06-03   6edb3df  
33321 share rows style                     @loneil              #698    #33321    2026-05-28   a117344  

<table>
  <tr><th>Title</th><th>Author</th><th>PR</th><th>Ticket</th><th>Merged_Date</th><th>Commit</th></tr>
  <tr><td>33467_directors_require_latin1</td><td>@mruff-aeq</td><td>#699</td><td><a href="https://github.com/bcgov/entity/issues/33467">#33467</a></td><td>2026-06-03</td><td>6edb3df</td></tr>
  <tr><td>33321 share rows style</td><td>@loneil</td><td>#698</td><td><a href="https://github.com/bcgov/entity/issues/33321">#33321</a></td><td>2026-05-28</td><td>a117344</td></tr>
</table>

bcgov/business-dashboard-ui

RUN    ENV       RESULT   ACTOR            COMMIT    CREATED (UTC)         MESSAGE                       
------ -------   ------   ---------------- -------   --------------------- ------------------------------
#475   prod      success  mruff-aeq        50f0a08   2026-06-04 19:03:25   Merge pull request #269 from  
#474   test      success  mruff-aeq        50f0a08   2026-06-01 20:47:58   Merge pull request #269 from  

test-release: merged PRs newer than the commit on test (#474 -> 50f0a08, excluded)
TITLE                                      AUTHOR               PR      TICKET    Merged_Date  COMMIT   
------------------------------------------ -------------------- ------- -------   -----------  -------  
Update CODEOWNERS to include new contribu  @TVWerdal            #270    NA        2026-05-29   94ba5fd  

<table>
  <tr><th>Title</th><th>Author</th><th>PR</th><th>Ticket</th><th>Merged_Date</th><th>Commit</th></tr>
  <tr><td>Update CODEOWNERS to include new contributors</td><td>@TVWerdal</td><td>#270</td><td>NA</td><td>2026-05-29</td><td>94ba5fd</td></tr>
</table>

bcgov/business-ui - checking web/business-registry-dashboard

RUN    ENV       RESULT   ACTOR            COMMIT    CREATED (UTC)         MESSAGE                       
------ -------   ------   ---------------- -------   --------------------- ------------------------------
#287   prod      success  loneil           bf604df   2026-05-28 20:30:41   33422 - affiliation success m 
#286   test      success  deetz99          bf604df   2026-05-27 21:25:36   33422 - affiliation success m 

test-release: merged PRs newer than the commit on test (#286 -> bf604df, excluded)
TITLE                                      AUTHOR               PR      TICKET    Merged_Date  COMMIT    IN-DIRS 
------------------------------------------ -------------------- ------- -------   -----------  -------   --------
33227 create/update Authentication and Ce  @eve-git             #486    #33421    2026-06-02   caf8d32   NA      
chore: update versions                     @app/github-actions  #484    NA        2026-05-29   e686301   NA      
32570 Do not show a dissolution alert for  @eve-git             #483    NA        2026-05-29   42efb5b   NA      
33513 correction ui and component update   @vysakh-menon-aot    #482    #33513    2026-05-29   4ea6d87   NA      
32483 - cleanup connectinputmenu componen  @deetz99             #481    #32483    2026-06-01   3088eeb   NA      
chore: update versions                     @app/github-actions  #480    NA        2026-05-27   60cb2e3   NA      

<table>
  <tr><th>Title</th><th>Author</th><th>PR</th><th>Ticket</th><th>Merged_Date</th><th>Commit</th><th>In-Dirs</th></tr>
  <tr><td>33227 create/update Authentication and Certification component</td><td>@eve-git</td><td>#486</td><td><a href="https://github.com/bcgov/entity/issues/33421">#33421</a></td><td>2026-06-02</td><td>caf8d32</td><td>NA</td></tr>
  <tr><td>chore: update versions</td><td>@app/github-actions</td><td>#484</td><td>NA</td><td>2026-05-29</td><td>e686301</td><td>NA</td></tr>
  <tr><td>32570 Do not show a dissolution alert for businesses in liquidation</td><td>@eve-git</td><td>#483</td><td>NA</td><td>2026-05-29</td><td>42efb5b</td><td>NA</td></tr>
  <tr><td>33513 correction ui and component update</td><td>@vysakh-menon-aot</td><td>#482</td><td><a href="https://github.com/bcgov/entity/issues/33513">#33513</a></td><td>2026-05-29</td><td>4ea6d87</td><td>NA</td></tr>
  <tr><td>32483 - cleanup connectinputmenu component</td><td>@deetz99</td><td>#481</td><td><a href="https://github.com/bcgov/entity/issues/32483">#32483</a></td><td>2026-06-01</td><td>3088eeb</td><td>NA</td></tr>
  <tr><td>chore: update versions</td><td>@app/github-actions</td><td>#480</td><td>NA</td><td>2026-05-27</td><td>60cb2e3</td><td>NA</td></tr>
</table>

Repo Versions:

business-edit-ui:       4.17.11
business-filings-ui:    8.3.13
business-create-ui:     5.18.14
business-dashboard-ui:  1.3.7
business-registry-dashboard:  1.2.17
legal-api:  2.171.8
```
