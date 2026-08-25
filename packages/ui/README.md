# packages/ui

Shared design system: shadcn/ui on React Aria primitives, with the tokens in
`design-tokens/`.

**Phase 4.** The tokens exist already (`design-tokens/tokens.css`,
`design-tokens/tailwind.config.ts`); the components do not.

Two rules that are cheap now and expensive to retrofit:

- **Logical properties only.** `ms-`/`me-`/`ps-`/`pe-`, `text-start`/`text-end`.
  Never `ml-`/`mr-`/`left-`/`right-`/`text-left`. This is what makes Persian
  RTL automatic instead of a per-screen patch.
- **Every amount, date and account code gets `.tabular-figure`**, which pins
  `direction: ltr; unicode-bidi: isolate`. A Persian UI must never flip the
  digit order of a dollar amount.
