# New database setup

## Paper Statuses

Status             | Description
---------          |--------------
new_arrival        | file request has been sent and waiting for package submission
with_author        | The package is with the author
with_replicator    | The package is with the replicator
replicator_back_de | The package is with the DE after being returned from the replicator
author_back_de     | The package is with the DE after being returned from the author
acceptable_package | The package is ready to be published to dataverse
published_package  | The package is published on dataverse


## Tables

papers             | iterations           | reports
---------          |--------------        |---------
paperID            | paperID              | case_id
contact1           | round                | replicator1
contact2           | case_id              | replicator2
editor             | replicator1          | time1
first_arrival_date | replicator2          | time2
title              | time1                | their_comments
status             | time2                | data_statement
round              | their_comments       | software
date_with_authors  | data_statement       | is_success
is_remote          | software             | is_remote
is_HPC             | is_success           | is_HPC
data_statement     | date_with_authors    | running_time_of_code
DOI                | date_arrived_from_authors         | 
 github URL       | date_assigned_repl        | 
 dataverse URL    | date_completed_repl       | 
 dataverse label  | date_decision_de     | 
  is_confidential | file_request_id      | 
                  | decision_de          | 
                  | is_remote            | 
                  | is_HPC               | 
                  | running_time_of_code | 



* `date_with_authors` is the date at which the authors are notified about the next round, i.e. it's the start of the current iteration.

## General Setup

Store a database in dropbox. duckdb file with 3 tables

Definition of a single **iteration**:

1. Date at which author gets notified via email about the next round
2. Date at which author resubmits package (need to get that from dropbox metadata - has to be from the destination folder) queried upon replicator assignment
3. Date at which DE assigns package
4. Date at which replicator returns
5. Date at which DE makes decision about Current round

## Actions

### DE Sends Initial File Request

1. package arrives via google form from editorial office. DE gets email alert.
2. action reads data from google form and writes to papers and interations.
   1. Iterations: ms, round = 1, case_id, date_with_authors = Dates.today(), file_request_id
   2. papers: ms, contact, editor, first_arrival_date = timestamp of google form, arrived_on_ee = arrived on ee, title, status = with_author, current_round = 1, date_with_authors = Dates.today()


### Action: replicator assignment after submission of file request

1. DE gets email alert about package arrival on dropbox.
2. Get date of package resubmission from dropbox folder TODO
3. Fill in replicator name(s) in iterations.
4. Fill in `date_arrived_from_authors` in iterations (date from 2.)
5. Fill in `date_assigned_repl = Dates.today()`
6. Set  paper.status = with_replicator


### Action: Replicator submits report

1. Email notification from google form.
2. DE looks at data on form and report, if all good, ingest, else cycle back to replicator, delete record in reports table and ask for a new submission via the form.
3. If report and table ok, ingest data: read row from google sheet and add to database in the reports table. 
4. From reports table, fill out fields on iterations table in row case_id (warn if email from form is not identical to email on iterations row, check ms, check round):
    1. Replicator hours
    2. Comments
    3. Data statement
    4. Date completed (from report timestamp)
    5. Software
    6. is_remote
    7. is_HPC
    8. Runtime 
5. Verify record on iterations
6. Delete record in reports table
7. Set paper.status = replicator_back_de
8. Set paper.is_remote, paper.is_HPC, paper.data_statement


### Action: DE rejects package and sends report

1. DE processes (edits) the report and saves a pdf in the correct location on dropbox
2. Sets papers.date_with_authors = Dates.today()
3. sets papers.status = with_authors, current_round = current_round + 1
4. Sets iterations: date_decision_de  = Dates.today(), decision_de = "rejected" 
5. Creates new file request and rembers ID 
6. Assembles email to author with above info
7. A new iteration starts now!
8. Copy from iterations of current record and create new row: ms, round = round + 1, case_id, file_request_id (point 5), date_with_authors = today


### Action: DE accepts package

1. DE sets paper.status to accepted_awaiting_DOI
2. DE sets iterations.date_decision_de = Dates.today()
3. DE sets iterations.decision_de = "accepted"
4. sends g2g email to ask for zenodo submission
5. sets papers.date_with_authors = Dates.today()

### Action: replicator re-assignment upon resubmission of package

1. DE gets email alert about package arrival on dropbox.
2. Get date of package resubmission from dropbox folder TODO
3. DE asks for re-assignment of same replicator(s)
4. action looks up ms and round-1 in iterations and copies replicator1 and replicator2 to record for this ms and round (which exists already) 
5. Fill in `date_arrived_from_authors` in iterations (date from 2.)
6. Fill in `date_assigned_repl = Dates.today()`
7. Set paper.status = with_replicator
8. send email to replicator(s) with instructions


### Action: DE checks md5 

1. DE gets email from zenodo
2. DE checks md5
3. if good, sets papers.DOI  
4. sets papers.status = acceptable_package
5. sends zg2g email
6. exports papers table to google sheets


## Reporting

1. List all unpublished papers
2. All published papers
3. List all papers which are with author, and for how many days
4. All papers with replicator, how many days
5. All papers with data editor, how many days
6. How many iterations for each paper (field “round”)
7. How many hours spent on a given paper
8. How many hours per iteration as a function of time (date_assigned_repl or date_completed)
9. How long did it take the authors to resubmit?
10. How long did it take the DE to make a decision?
11. How long did it take the DE to assign an arrived paper?