# Contributing

Thanks for your interest in Used Equipment Yards. Please read this before opening a pull request.

## Pull requests: translations only

**This project only accepts pull requests for translations.** Code, XML, and documentation pull
requests will be closed without review, however well intentioned.

This isn't about the quality of the work. It is that I am very opinionated on how I want the code to be implemented and do not wish to back and forth with contributors to ship a PR. Usually it relates to a bug and I would like to address those in my own style as soon as possible.

### What is accepted

Additions and corrections to the files in [`languages/`](languages/):

| | |
|---|---|
| `l10n_en.xml` | English (the reference file — all keys originate here) |
| `l10n_br.xml` | Brazilian Portuguese |
| `l10n_de.xml` | German |
| `l10n_fr.xml` | French |
| `l10n_it.xml` | Italian |

New languages are welcome — copy `l10n_en.xml`, translate the values, and name the file with the
appropriate language code.

### Translation PR guidelines

- **One language per pull request.**
- **Only touch files in `languages/`.** A PR that also changes code will be closed; please split it.
- **Never change the `name` attribute of an entry** — only the text value. The `name` is what the
  code looks up, so renaming one breaks that string in-game.
- **Don't add or remove keys.** If `l10n_en.xml` is missing a string you need, open an issue instead.
- **Keep placeholders intact.** Anything like `%s`, `%d`, or `%.1f` must appear in your translation,
  in an order that makes sense for the sentence.
- **Mind the length.** Menu labels and HUD text have limited space; a translation two or three times
  longer than the English will get clipped on screen.
- **Leave existing translations for other languages alone**, even if you spot a mistake — report it
  in an issue so the person who wrote it can confirm.

## Everything else

Bug reports and feature requests are very welcome — just not as pull requests.

- **Bugs and feature requests** — [GitHub Issues](https://github.com/Ozz-Modding/FS25_UsedEquipmentYards/issues).
  For a bug, please include your `log.txt`, the map you're playing, whether it's singleplayer or
  multiplayer, and the other mods you have loaded.
- **Anything else** — [Discord](https://discord.gg/9pVhkV9KRQ).

Good issues genuinely shape this mod, and a well-described bug report is worth more here than a
patch.
