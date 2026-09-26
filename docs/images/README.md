# README illustration

`reading-workshop-v1.png` is a supporting editorial illustration, generated with
the built-in ImageGen tool. It is not a screenshot of browse. The real app
captures live in `../screenshots/`.

The direction borrows Codegraff's paper, ink and restrained coral from
`zigrepper/design.md`, with a lighter background and more space for browse.

## Generation prompt

```text
Use case: illustration-story
Asset type: wide supporting illustration for browse macOS browser README, an editorial visual separate from real app screenshots.
Primary request: A quiet reading workshop: two composed black field mice at a very simple open reading desk, one following a blank open paper page and the other retrieving a thin blank reference sheet from a small paper archive. Their collaboration suggests browsing and researching beside a page.
Style/medium: restrained Japanese woodblock and 1960s technical-editorial print influence from Codegraff's design system, tactile dry ink and delicate rice-paper fibers. Much lighter, airier and more minimal than a busy technical workshop.
Composition/framing: wide horizontal 3:1 banner; subjects occupy central half, generous almost-white negative space, flat paper background, one clear scene, no enclosing frame.
Color palette: near-white warm rice #fffdf8, charcoal #292622, sparse muted coral #d45a43 and pale warm grey. High-key overall with small ink areas.
Constraints: absolutely no text, letters, numbers, logos, watermarks, borders, UI, computers, screenshots, or invented product controls. Calm precise anatomical mice with coherent paws. No cute mascot styling, photorealistic fur, gradients, glossy 3D, or heavy shadows.
```

## Quiet desktop backdrop

`quiet-wallpaper-v1.png` was generated with the built-in ImageGen tool for
the bar-free browser showcase. It is an original macOS-style backdrop, not
an Apple wallpaper. The browser capture is taken separately from a test profile.

`../screenshots/quiet-window.png` is a fresh whole-window capture of browse
showing [Japan on Wikipedia](https://en.wikipedia.org/wiki/Japan), with the
tab bar hidden using ⌘S. It was captured from an isolated copy of the installed
app in the `readme-quiet` test profile, not from the user's browsing session.
`quiet-showcase.html` places that unchanged capture over the generated backdrop;
`../screenshots/quiet-desktop.png` is its 1600 × 1050 browser render. The layout
adds window rounding and a shadow without redrawing the page or adding controls.

`browser-comparison.html` displays `../screenshots/chrome-window.png` and
`../screenshots/quiet-window.png` at equal scale. Both were captured on the same
Mac at an outer window size of 1100 × 750 points (2200 × 1500 pixels). Chrome 153
uses its standard window; browse has its tab bar hidden. Chrome used an isolated
temporary profile. `../screenshots/browser-comparison.png` is the rendered layout,
not a performance benchmark. The captured browser interfaces are not generated.

`../screenshots/event-registration-window.png` is a real browse capture of
`../demos/event-registration.html`, a local event-registration demo inspired by
the clean presentation of event signup pages. It uses fictional details and was
filled through the browser's bench tools. No signup was submitted, no agent
conversation was fabricated, and the form is not an official Luma page.

`../screenshots/column-rounded-light.png` and `column-rounded-dark.png` show
the actual CI build of PR #3 (source commit `8452b4d`) in an isolated test profile.
The conversation is a seeded UI fixture visibly labeled “Layout preview — sample
conversation”; it is not evidence of a model completing a task. The light capture
uses a 440-point column, and the dark capture checks the 280-point minimum width.
These images preview the proposed rounded column, not the installed release.

```text
Use case: stylized-concept
Asset type: desktop wallpaper backdrop for a real macOS browser screenshot showcase.
Primary request: Create a beautiful quiet original macOS-style abstract landscape wallpaper, wide 16:10, soft layered coastal hills flowing into a calm sea, atmospheric dawn light. Airy pale blue and misty lavender, warm ivory light, restrained pale peach horizon. Smooth refined shapes and subtly photographic atmospheric depth, sophisticated native desktop wallpaper feel. Center area calm and unobtrusive as it will sit behind a browser window. No browser window, no UI, no dock or menu bar, no text or logos. No harsh saturation, no noise, no busy detail.
```
