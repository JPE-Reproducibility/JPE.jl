
# Stage R: LLM-based README review -- a deeper complement to PackageScanner's
# deterministic `readme_structure_audit` (Stage B). Stage B's regex-based
# section checklist/citation-proximity check is fast and free but shallow --
# it can only tell you a section header exists, not whether the content is
# actually adequate (e.g. "Software requirements" matched on a bare mention
# of "Python" with no version, no package list, no lockfile). This runs the
# actual README text, plus a Glob/Grep look at the replication package
# itself, through a long review rubric via `claude -p`, mirroring Stage C/D's
# budget-conscious shape (single turn, `--safe-mode`, read-only tools,
# `--json-schema` for a parseable result).
#
# The rubric itself is vendored, not written here: see
# `README_REVIEW_RUBRIC_SOURCE` below. `JPE_OVERRIDE_PREAMBLE` is prepended
# at call time (not baked into the vendored file) specifically so that file
# can be swapped wholesale on a resync with upstream, with no manual
# re-merge of JPE-specific edits.
#
# Deliberately NOT folded into preprocess()'s runner_precheck.jl like Stage
# C/D: this is a new, separate, opinionated qualitative review (another paid
# `claude` call), kept as its own DE-triggered step (`review_paper_readme` in
# readme_review.jl) rather than run unconditionally on every preprocess().

"""
    README_REVIEW_RUBRIC_SOURCE

Provenance of the vendored rubric at `README_REVIEW_PROMPT_PATH`: upstream
repo, the commit it was copied from, and the skill version at that commit.
Update this alongside the file itself on a resync -- it is the only record
of which upstream state produced the vendored copy, since the file itself
is kept byte-identical to upstream's generated output (no local edits) to
keep resyncs a clean overwrite rather than a merge.
"""
const README_REVIEW_RUBRIC_SOURCE = (
    repo = "https://github.com/social-science-data-editors/readme-bot",
    commit = "7d53198e72caaea700faf4f231c805e4ecdc423b",
    skill_version = "0.1.0",
    vendored_file = "prompts/readme-review-prompt.md",  # upstream's build.sh output; see its README
)

"""
    README_REVIEW_PROMPT_PATH

The vendored rubric: upstream's `scripts/build.sh` output, which
concatenates `skills/readme-review/SKILL.md` with its four `references/*.md`
appendices into one self-contained prompt (upstream's own "for chat tools
without skill support" artifact -- exactly the shape a headless `claude -p`
call needs). Not inlined as a Julia string, and not hand-edited: see
`README_REVIEW_RUBRIC_SOURCE`.
"""
const README_REVIEW_PROMPT_PATH = joinpath(@__DIR__, "prompts", "readme-review-prompt.md")

"""
    readme_review_prompt() -> String

Read the vendored rubric from `README_REVIEW_PROMPT_PATH`, unmodified.
"""
readme_review_prompt() = read(README_REVIEW_PROMPT_PATH, String)

"""
    README_REVIEW_JPE_OVERRIDE_PREAMBLE

The rubric at `README_REVIEW_PROMPT_PATH` was written for an interactive
Claude Code/claude.ai session with a `Write` tool and a human who reads the
survey link it ends with. Neither holds here: this call is headless,
`Read`/`Glob`/`Grep`-only, and `claude`'s only output channel back to Julia
is `--json-schema`'s `structured_output`. This preamble states the three
deviations explicitly rather than editing the vendored rubric to match --
keeps the vendored file a clean, re-syncable copy of upstream.
"""
const README_REVIEW_JPE_OVERRIDE_PREAMBLE = """
This review follows the rubric below, with three deviations for this
automated, headless call (not the interactive Claude Code skill the rubric
was written for):

1. You do not have a `Write` tool. Do not attempt to write `README-review.md`
   or `README-ai-edited.md` to disk yourself -- return both as the
   `review_markdown` and `edited_readme_markdown` fields of the JSON schema
   given to you, in full Markdown, exactly as you would otherwise have
   written them to those files.
2. The replication package is always available at the path given below --
   treat this as edit mode always (never review-only), and always produce
   the edited copy.
3. Omit the "Feedback (human task)" section's instructions and the final
   feedback-survey line entirely from your `review_markdown` -- this call
   has no connection to the upstream skill's feedback survey.

The rubric:

"""

"""
    README_REVIEW_JSON_SCHEMA

JSON schema passed to `claude -p --json-schema`, forcing the two outputs the
vendored rubric otherwise describes as separate files (`README-review.md`,
`README-ai-edited.md`, see `README_REVIEW_JPE_OVERRIDE_PREAMBLE` point 1)
into one parseable response. Both fields are full Markdown text, not
structured data -- the rubric's own section/finding structure stays as
prose inside `review_markdown`, same as Stage C/D's schemas never ask the
model to pre-render markdown for fields that are themselves markdown
documents.
"""
const README_REVIEW_JSON_SCHEMA = """
{"type":"object","properties":{
"review_markdown":{"type":"string"},
"edited_readme_markdown":{"type":"string"}
},"required":["review_markdown","edited_readme_markdown"]}
"""

"""
    build_claude_readme_review_cmd(readme_path::String, package_dir::String; effort = "high")

The `Cmd` for the headless README-review call. Split out from
`run_claude_readme_review` so the flags are testable without actually
invoking `claude` (no live API/CLI calls in tests), mirroring
`build_claude_claims_cmd`/`build_crosscheck_cmd`.

`effort` defaults to `"high"`, not Stage C/D's `"medium"`: the rubric asks
for a long, multi-section, quote-and-cite review rather than a compact
structured extraction, so it needs more reasoning budget.

Grants `Read`, `Glob`, and `Grep` (not Stage C/D's `Read`-only): the
rubric's package checks (`references/package-checks.md`, vendored into the
prompt) call for listing files and grepping for seeds/software/output
names across the whole package, which `Read` alone cannot do. Still no
`Bash` and no code execution.

`--add-dir package_dir` grants access to the whole replication package (the
README itself is always found somewhere under it, see
`find_readme_in_dir`), not just the README's own directory -- needed for
the package checks above. Explicit rather than relying on `--safe-mode`'s
verbatim-absolute-path heuristic, matching Stage C/D's documented reasoning
for the same flag.
"""
function build_claude_readme_review_cmd(readme_path::String, package_dir::String; effort::String = "high")
    bin = claude_binary()
    isnothing(bin) && error("claude CLI not found on PATH")

    prompt = """
    $README_REVIEW_JPE_OVERRIDE_PREAMBLE$(readme_review_prompt())

    The README file to review is located at the absolute path: $readme_path
    Read it fully before beginning your section-by-section review.

    The replication package root is located at the absolute path: $package_dir
    Use Glob and Grep (not Bash, no code execution) to inspect its files for
    the package checks in the rubric above.
    """

    addenv(
        `$bin -p $prompt
         --output-format json --tools Read,Glob,Grep --safe-mode --effort $effort
         --add-dir $package_dir
         --json-schema $README_REVIEW_JSON_SCHEMA`,
        "CLAUDE_CONFIG_DIR" => claude_jpe_config_dir(),
    )
end

"""
    run_claude_readme_review(readme_path::String, package_dir::String; effort = "high")

Run the headless README-review call and return
`(review_markdown = <markdown text>, edited_readme_markdown = <markdown text>,
cost_usd = <reported cost>, usage = <raw usage Dict or missing>)`.

`usage` is passed through verbatim from the CLI's `--output-format json`
envelope (typically `input_tokens`/`output_tokens`/cache fields) -- kept raw
rather than reduced to one number, so a caller unsure whether `effort="high"`
is worth its cost on this rubric can actually see the token burn, not just
`cost_usd`.
"""
function run_claude_readme_review(readme_path::String, package_dir::String; effort::String = "high")
    cmd = build_claude_readme_review_cmd(readme_path, package_dir; effort = effort)
    out = read(cmd, String)
    parsed = JSON.parse(out)

    get(parsed, "is_error", true) == false || error("claude -p failed: $(get(parsed, "result", "unknown error"))")

    structured = parsed["structured_output"]
    return (
        review_markdown = structured["review_markdown"],
        edited_readme_markdown = structured["edited_readme_markdown"],
        cost_usd = get(parsed, "total_cost_usd", missing),
        usage = get(parsed, "usage", missing),
    )
end
