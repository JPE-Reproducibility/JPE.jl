

JO_email() = haskey(ENV,"JPE_TEST") ? "florian.oswald@unito.it" : "jpe@press.uchicago.edu"
author_email(mail::String) = haskey(ENV,"JPE_TEST") ? "florian.oswald@unito.it" : mail

function gmail_assign(first1,email1,caseID,download_url, repo_url; first2 = nothing,email2 = nothing,back = false)
    subject = if back
        "The JPE package $caseID is back"
    else
        "I assigned you the $caseID package"
    end
    to = isnothing(email2) ? [author_email(email1)] : [author_email(email1), author_email(email2)]
    body = gmail_assign_body(first1,caseID,download_url,repo_url,first2 = first2, back = back)
    gmail_send(
        to,
        subject,
        body,
        []
    )
end


function gmail_assign_body(first1,caseID,download_url, repo_url; first2 = nothing,back = false)

    deadline = Dates.format(today() + Day(10), dateformat"d U Y")

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
        <h2>Getting Started with Report 👩🏽‍💻🧑🏿‍💻</h2>

        Start with this table:
        <br>
        <br>
        
        <table border="1" cellpadding="4" cellspacing="0" width="100%">
        <tr>
            <td width="20%">Case ID</td>
            <td>$(caseID)</td>
        </tr>
        <tr>
            <td width="20%">Full Package Download Link</td>
            <td>$(download_url)</td>
        </tr>
        <tr>
            <td width="20%">git repo</td>
            <td>$(repo_url)</td>
        </tr>
        <tr>
            <td width="20%">Report Form</td>
            <td>https://forms.gle/u9Mp87shmZc94gzT9</td>
        </tr>
        <tr>
            <td width="20%">Deadline</td>
            <td>$(deadline)</td>
        </tr>
        </table>
      
        <br>
        Go to the git repo and look at the readme, which contains step by step instructions.

        <h2>Report Submission 🗒️</h2>

        <ol>
        <li>You must edit the <code>.qmd</code> in the git repo, and compile it locally to pdf format. I recommend using the typst engine inside quarto, works much better than latex.</li>
        <li>Once you have the report compiled, committed, and pushed back to the remote, you <b>must</b> fill out this online form: https://forms.gle/u9Mp87shmZc94gzT9. <i>This will determine the amount of time (days) you spent on this, so until you submit the form, you keep wasting days</i>. Also, it is where you log your hours, so no submitted form, no money.
        </li>
        </ol>

        <h2>Deadline ⏰</h2>

        As usual, we aim for your report to arrive within the next 10 days, i.e. by $(deadline).


        <h2>Warning ⚠️</h2>


        ⚠️ Do not forward or otherwise share the content in this email. You are bound by a confidentiality agreement with the University of Chicago - and I trust you, so don't let me down.
        <br>
        <br>

        <h2>Help?</h2>

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

    to = isnothing(email2) ? [author_email(email1)] : [author_email(email1), author_email(email2)]
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


function gmail_file_request(name,paperID,title,url,email1;email2 = nothing, JO = false)
    if JO
        body = gmail_file_request_JO_body(name,paperID,title,url)
    gmail_send(
        email1,
        "Request for Paper (PDF) upload from DE for $paperID",
        body,
        []
    )

    else
        to = isnothing(email2) ? [author_email(email1)] : [author_email(email1), author_email(email2)]
        body = gmail_file_request_body(name,paperID,title,url)
        gmail_send(
            to,
            "JPE Replication Package $paperID Upload Request",
            body,
            []
        )
    end
end

function gmail_file_request_JO_body(authorlast,paperID,title,url)
    @debug authorlast paperID title url
    m1 = """
    <h1>Data Editor's Upload Request</h1>

    <table border="1" cellpadding="4" cellspacing="0" width="100%">
    <tr>
        <td width="10%">paper ID</td>
        <td>$(paperID)</td>
    </tr>
    <tr>
        <td width="10%">Title</td>
        <td>$(title)</td>
    </tr>
    <tr>
        <td width="10%">Author</td>
        <td>$(authorlast)</td>
    </tr>
    <tr>
        <td width="10%">Upload link</td>
        <td>$(url)</td>
    </tr>
    </table>
    <br>
    <br>
    Dear Journal Office,
    <br>
    <br>
    Please upload the conditionally accepted version of the paper and online appendix in PDF format of $paperID, by author $(authorlast) and titled \"$title\", using this dropbox file request link:
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
    @debug first paperID title url

    m1 = """
    Dear $first,
    <br>
    <br>
    I am the Data Editor of the JPE.
    I would like to invite you to submit your replication package for your paper titled \"$title\", with manuscript ID $paperID, as a single zip file via this dropbox file request link:
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