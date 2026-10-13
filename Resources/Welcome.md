# Welcome

This is a plain text editor for writing in Markdown. What you see is what you typed: the syntax stays visible, in a quiet gray, so your files stay **portable** and *readable* anywhere.

## Writing

Press ⌘D for Focus Mode. As a matter of fact, it dims everything except the sentence you are writing and keeps it in the middle of the screen. Choose Sentence, Paragraph or Typewriter in the Focus menu.

Syntax Highlight (⇧⌘D) colors adjectives, nouns, adverbs, verbs and conjunctions. Style Check (⌥⇧⌘D) basically crosses out fillers, clichés and redundancies like the end result. It never deletes anything; you decide.

## Formatting

- ⌘1 to ⌘6 for headings, ⌘B **bold**, ⌘I *italic*, ⌥⌘U ~~strikethrough~~, ⇧⌘U ==highlight==
- ⌘J `code`, ⇧⌘J code block, ⌘K [links](https://example.com), ⇧⌘K [[Wikilinks]], ⌃⌘K footnotes[^1]
- ⌘L lists, ⌥⌘L task lists, ⇧⌘L ordered lists, ⌥⌘X to tick a task off

- [x] Read the welcome note
- [ ] Write something of your own #ideas

> Return continues a list or quote. Return on an empty item ends it.

## Library

⌃⌘S shows the Library: your locations, favorites, smart folders and #hashtags. ⌘P opens any note or folder by typing a few letters of its name (fuzzy, with fzf if you have it). ⌘D deletes the note selected in the notes list. Files are named after their first line.

Type `/` at the start of a line to embed a file as a content block, or drag one in.

## Preview

⌘R shows the Preview next to the editor. Pick a template there, then export with ⇧⌘E to PDF, HTML, Word or Markdown.

---

[^1]: Footnotes collect at the end of the document.
