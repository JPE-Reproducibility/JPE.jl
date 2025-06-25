

function gmail_assign(first1,email1,caseID,download_url, repo_url; first2 = nothing,email2 = nothing,back = false)
    subject = if back
        "The JPE package $caseID is back"
    else
        "I assigned you the $caseID package"
    end
    to = isnothing(email2) ? [email1] : [email1, email2]
    body = gmail_assign_body(first1,caseID,download_url,repo_url,first2 = first2, back = back)
    gmail_send(
        to,
        subject,
        body,
        []
    )
end


function gmail_assign_body(first1,caseID,download_url, repo_url; first2 = nothing,back = false)

    repnames = isnothing(first2) ? first1 : string(first1," and ",first2)

    m1 = if !back
        """
        Hi $(repnames)!
        <br>
        <br>
        I assigned you the package $caseID.
        <br>
        <br>
        """
    else
        """
        Hi $(repnames)!
        <br>
        <br>
        The $caseID package is back for the next round.
        <br>
        <br>
        """
    end
        
    m2 = """
        You need two pieces to get started:
        <br>

        <ol>
        <li>This link to download the submitted package: $download_url </li>
        <li>This link to access the repo for this package on github: $repo_url You will find the template report in that repository.</li>
        </ol>
        ⚠️ Do not forward or otherwise share the content in this email.
        <br>
        <br>
        Don't hesitate to reach out on slack for any ongoing issues with the replication. Let's talk about computational requirements there etc.
        <br>
        <br>
        Thanks for your help with this package!
        <br>
        <br>
        Florian
        """
    string(m1,m2,signature())

end




case_id(journal,author,ms,round) = string(journal,"-",author,"-",ms,"-R",round)

function gmail_g2g_body(first,paperID)

    m1 = """
    Dear $first,
    <br>
    <br>
    I am happy to tell you that your replication package for paper $paperID is good to go for me! 🚀
    <br>
    Here are the next steps:   
    <br>

    <ol>
    <li>the journal office will do something.</li>
    <li>you must upload your package on the JPE dataverse. Here are the instructions</li>
    </ol>
    <br>
    🚨 It is of great importance that you do not modify the files in your submitted package anymore. We will check the final version of the package you sent us against what you will publish on dataverse in a very strict (and automated) fashion.
    Unless the files on dataverse are <i>exactly identical</i> to ours, this check will fail.
    Please remove the letter to the data editor before you submit - and do <b>not</b> include any confidential data.
    <br>

    After these steps are completed, your files will be sent back to your editor for final acceptance.
    All this should happen before too long.
    In the meantime, if you have any queries regarding the publication process, please contact jpe@press.uchicago.edu.

    <br>
    <br>
    Thank you again for your cooperation, and congratulations on an excellent replication package.
    <br>
    <br>
    Best wishes,<br>
    Florian
    """

    string(m1,signature())

end


function gmail_rnr(first,paperID,title,url,email1,attachment;email2 = nothing)
    if !isfile(attachment)
        error("the file $attachment does not exist")
    end

    to = isnothing(email2) ? [email1] : [email1, email2]
    body = gmail_rnr_body(first,paperID,title,url)
    gmail_draft(
        to,
        "JPE Reproducibility Checks Outcome",
        body,
        [attachment]
    )
end

function gmail_rnr_body(first,paperID,title,url)
    m1 = """
    Dear $first,
    <br>
    <br>
    Thank you for providing us with the replication
    package for your paper $paperID, titled \"$title\".
    Please find attached the report with the outcome of our checks.
    As you will see in the report, the reproducibility team has identified
    a few issues that need to be fixed.

    <ol>
    <li>Item 1</li>
    <li>Item 2.</li>
    </ol>

    Could you please address these issues and resubmit the package like before? Please use this link:<br><br>

    $url

    <br>
    <br>

    We need you to submit the entire package again because updating
    the replication package ourselves increases the potential risk
    that the files you intend to submit for possible publication may be mishandled.

    <br>
    <br>

    Please also submit a letter addressed to me explaining how you
    dealt with each of the issues raised in the report.
    Once your package has arrived, I will return it to the reproducibility team 
    for another check.
    <br>
    <br>
    It is our policy to ask for the submission of your replication package within 30 days, i.e., by $(Dates.format(today() + Day(30), dateformat"d U Y")).
    <br>
    <br>

    I would like to thank you for your cooperation and I
    look forward to receiving your revised package.
    <br>
    <br>

    Best wishes,<br>
    Florian
    """

    string(m1,signature())
end




function gmail_file_request(first,paperID,title,url,email1;email2 = nothing, JO = false)
    if JO
        body = gmail_file_request_JO_body(first,paperID,title,url)
    gmail_send(
        email1,
        "Request for Paper (PDF) upload from DE",
        body,
        []
    )

    else
        to = isnothing(email2) ? [email1] : [email1, email2]
        body = gmail_file_request_body(first,paperID,title,url)
        gmail_send(
            to,
            "JPE Replication Package Upload Request",
            body,
            []
        )
    end
end

function gmail_file_request_JO_body(first,paperID,title,url)
    m1 = """
    Dear $first,
    <br>
    <br>
    Please upload the conditionally accepted versions of paper and appendix in PDF format of $paperID, titled \"$title\", using this dropbox file request link:
    <br>
    <br>
    $url
    <br>
    <br>
    Thanks!
    <br>
    <br>

    Best wishes,<br>
    Florian
    """

    string(m1,signature())
end

function gmail_file_request_body(first,paperID,title,url)
    m1 = """
    Dear $first,
    <br>
    <br>
    I am the Data Editor of the JPE.
    I would like to invite you to submit your replication package for your paper for $paperID, titled \"$title\", as a single zip file via this dropbox file request link:
    <br>
    <br>
    $url
    <br>
    <br>

    Please review the required contents of your replication package described at https://jpedataeditor.github.io/ .
    <br>
    <br>
    It is our policy to ask for the submission of your replication package within 30 days, i.e., by $(Dates.format(today() + Day(30), dateformat"d U Y")). If you foresee a problem with meeting this deadline, you will need to request an extension. 
    <br>
    <br>

    I'm looking forward to receiving your replication package. 
    <br>
    <br>

    Best wishes,<br>
    Florian
    """

    string(m1,signature())
end

function signature()
    """
    <br>
    <br>
    --<br>
    Florian Oswald<br>
    Data Editor<br>
    Journal of Political Economy<br>
    email: jpe.dataeditor@gmail.com<br>
    web (JPE) : https://jpedataeditor.github.io/<br>
    web (personal) : https://floswald.github.io/
    """
end

# low level functions interfacing with the python client
function gmail_send(to,subject,body,attachments; from = "'JPE Data Editor' <jpe.dataeditor@gmail.com>")
    py"send_email"(to,subject,body,from,attachments)
end

function gmail_draft(to,subject,body,attachments; from = "'JPE Data Editor' <jpe.dataeditor@gmail.com>")
    py"create_draft"(to,subject,body,from,attachments)
end