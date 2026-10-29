# AGENTS.md — Red Hat Knowledgebase (KCS) markdown rules for `faq_draft.md`

Source: [Markdown Help — Red Hat Customer Portal (article 7056942)](https://access.redhat.com/articles/7056942)

## Scope

**These rules apply to one file only: [`faq_draft.md`](faq_draft.md).**

That file is destined for the Red Hat Customer Portal as a KCS article, so it must
follow Red Hat Knowledgebase markdown rather than GitHub-flavored markdown. Do not
apply anything in this document to any other file — including other files in this
`docs/` directory. For every other markdown file in the repository, follow the
top-level [`AGENTS.md`](../AGENTS.md) and ordinary GitHub-flavored markdown.

The Red Hat Knowledgebase uses **markdown, not HTML**. Inline HTML is currently
accepted in some fields but is **not encouraged** — do not emit it.

Different Customer Portal fields use different markdown variants, so a construct
that renders in one field may break in another. The portal is migrating everything
(including the KCS editing form) to **CommonMark**. The KCS editing form is *mostly*
CommonMark today; the exceptions are called out as **Non-CommonMark** below.

## Rules for agents

0. **Check the file first.** If you are not editing `faq_draft.md`, stop reading —
   none of the rules below apply.
1. **Write CommonMark-compatible syntax.** When a construct has both a portable and
   a Red Hat–specific form, emit the portable one. Syntax that only works in today's
   KCS parser will break as the parser changes.
2. **Never emit inline HTML.** Use markdown equivalents.
3. **Surround block elements with blank lines** — blockquotes, code blocks, lists,
   and tables all need a blank line before and after.
4. **Use spaces, never tabs**, for all indentation. Tabs do not work consistently.
5. **Avoid the constructs marked Non-CommonMark** unless the user explicitly asks
   for them: internal anchor links, footnotes, and reliance on soft line breaks.
6. **Reserve `#` (H1) for the article title.** Body headings start at `##`.
7. **Warn the user before emitting advanced formatting.** Some constructs can break
   the KCS editing form badly enough that the only recovery is refreshing the page
   and losing all edits (see [Line breaks](#line-breaks)). Suggest testing in a
   draft first.
8. **Escape literal formatting characters** with a backslash: `\*`, `\-`, `\#`,
   `\>`, `\[`, `\]`, `\(`, `\)`, `\\`, `` \` ``.

## Blockquotes

Separate from surrounding text with blank lines; begin each line with `>`.

```markdown
> this is a blockquote
```

## Code blocks

Three forms are accepted. **Prefer triple backticks** — it is the most widely
supported form across the Customer Portal, VS Code/VSCodium, vim, and GitHub/GitLab.

````markdown
```
this is a
code block
```
````

Triple tildes also work and are specific to the Customer Portal:

```markdown
~~~
this is a
code block
~~~
```

Indenting every line by 4 spaces works as well. Separate it from surrounding text
with blank lines, and use literal spaces — tab is unreliable.

```markdown
    this is a
    code block
```

### Code blocks inside lists

Indentation is cumulative: **4 spaces per list level, plus 4 for the code block.**

- Code under a top-level list item: **8 spaces**.
- Code under a once-indented list item: **12 spaces**.

```markdown
- list item A

        this is a code block under list item A.
        Note: you must indent 8 spaces for this code block.

    1. indented list item 1

            this is a code block under indented list item 1.
            Note: you must indent 12 spaces for this code block.

        and also you would like to put another code block under the same level
        (note: start this line with 8 spaces of indent):

            this is another code block under indented list item 1.
            Note: you must indent 12 spaces for this code block.

    2. indented list item 2

            this is a code block under indented list item 2.
            Note: you must also indent 12 spaces for this code block.
```

Fenced blocks can be indented into lists the same way — add 4 spaces beyond the
list item's own indentation:

```markdown
- Code can also be indented within lists.
    - Add an additional 4 spaces for the code block.

        ~~~
        # some_prop:
            - some_value
        ~~~
```

## Inline code

Surround the word(s) with single backticks: `` `backquote` ``.

## Emphasis

| Intent | Syntax |
| --- | --- |
| Italics | `*single asterisks*` |
| Bold | `**double asterisks**` |
| Bold italics | `***triple asterisks***` |
| Bold italics dropping to italics | `***triple, end with** to get into italics, then end that*` |

## Footnotes

**Non-CommonMark.** Use `[^n]` with a unique number per footnote. Two links to the
same footnote are not supported. The colon in the definition is **required**.

```markdown
Here is an example of text that requires a footnote.[^1]

[^1]: Here is the actual footnote.
```

## Headers

Start the line with one to six `#`. A **space after the `#`s is required** —
`# My Header`, not `#My Header`.

```markdown
# H1 (almost always reserved for the title only)
## H2
### H3
#### H4
##### H5
###### H6
```

The first two levels may alternatively be underlined. The underline must be at
least as long as the title.

```markdown
Header 1
=========

Header 2
---------
```

## Horizontal rules

Three hyphens (`---`) or three underscores (`___`) on a line of their own.

## Line breaks

End a line with **two trailing spaces** to force a line break.

**Non-CommonMark behavior.** CommonMark distinguishes *hard* line breaks (two
trailing spaces) from *soft* ones (a bare newline), and only hard breaks are
guaranteed to start a new line. The current KCS parser treats both as a new line,
but that may change after the CommonMark switch — so emit two trailing spaces
wherever a break matters.

Observed KCS parser behavior:

- All line breaks in the input are preserved.
- Line breaks are sometimes inserted into very long lines.

Both can corrupt HTML-flavored content. Be especially careful with indented
HTML/XML/SVG containing blank lines — the following breaks rendering for the rest
of the page, because the closing `</style>` gets translated into a code block:

```markdown
<svg>
    <defs>
        <style>
            .selector {}

        </style>
    </defs>
</svg>
```

## Links

### External links

Link text in square brackets, URL in parentheses. The title is optional and goes
in double quotes inside the parentheses.

```markdown
This is [a markdown example](http://example.com/ "Title") inline link.
```

### Reference links

Keep all URLs in one place and reference them by name. Define a reference on its
own line — anywhere in the body — as `[name]: URL "optional title"`.

```markdown
Here we will use the [My Cool Link][] link reference.
Here we will use the [example link reference][My Cool Link 2].
Other text that has nothing to do with our links.

[My Cool Link]: http://example.com "What ever you would describe My Cool Link as"
[My Cool Link 2]: http://example.com/other-place "Hover title for My Cool Link 2"
```

Use `[name][]` to use the reference's own name as the link text, or
`[different label][name]` to relabel it. Definition lines are not rendered.

### Internal (anchored) links

**Non-CommonMark.** Anchors work in the current KCS parser but are not part of the
CommonMark specification, and the parser's support for them has changed over time
(all three forms below work as of 2016-01-06; earlier only the second did).

Append `{#anchor-name}` to a header, then link to it with `(#anchor-name)`:

```markdown
## H2 ## {#header}
## H2 {#header}

H2 {#header}
------------
```

```markdown
Example Header 1 {#example_header1}
-----------------------------------

This is [a markdown example 1](#example_header1) internal link.

### Example Header 2 ## {#example_header2}

This is [a markdown example 2](#example_header2) internal link.
```

## Lists

Separate lists from surrounding text with blank lines. To nest, indent by
**4 spaces** before the marker.

### Ordered lists

Require an empty line before and after. Begin each line with a number and a period.

```markdown
1. ordered list item 1
2. ordered list item 2
```

If list items contain multiple paragraphs, indent each paragraph by 4 spaces per
level or markdown may restart the numbering. Alternatively use `1)` instead of
`1.` — markdown does not treat a number followed by a parenthesis as a list, so
verify the numbering yourself if you do.

### Unordered lists

Begin lines with `*`, `+`, or `-`.

```markdown
- unordered list item 1
- unordered list item 2
    - indented item
```

## Tables

Column headers go on the first line, a separator row next, then one line per row.
Separate columns with the pipe (`|`) character.

```markdown
Header 1 | Header 2
--------- | ---------
Content 1 | Content 3
Content 2 | Content 4
```

Renders as:

| Header 1 | Header 2 |
| --- | --- |
| Content 1 | Content 3 |
| Content 2 | Content 4 |

## Images

1. Upload the image to the KCS article in question.
2. Right-click the resulting link to copy the image URL.
3. Reference it with `![alt text](http://image_url)`.

Do not violate copyright by using unauthorized images. Keep a worldwide perspective
in mind, as laws vary by country, and default to Red Hat brand–approved images.

## More information

- [CommonMark specification 0.31.2](https://spec.commonmark.org/0.31.2/)
- [Daring Fireball: Markdown syntax](http://daringfireball.net/projects/markdown/syntax)
- [PHP Markdown Extra](http://michelf.ca/projects/php-markdown/extra/)

The syntax on those sites may differ slightly from the markdown used by the Red Hat
Knowledgebase.
