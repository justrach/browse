# Research with Codegraff

## Beside a page

With Codegraff enabled, press **.** while reading a page to open and focus its side conversation. Periods in forms, page editors, the address field and the composer remain punctuation. You can also choose the **Ask** tab, then **Beside the page** in the conversation header. The context row identifies the page by title and domain. **×** excludes it from the next message; **+** includes it again. **Pin** keeps that page attached as you change tabs; **Unpin** follows the page in front again.

Turn on **Settings › Agent › Ask about selected text** to add **Ask Codegraff about Selection** to the page's context menu. It prepares a draft with a removable selected-text preview and source link. Review or expand the preview, change the question, then send. Existing draft words are preserved. Password selections are excluded. Excerpts keep their original text and source when you switch tabs, navigate the source or queue a follow-up. Exclude the page context to send only the excerpt.

Start with “Summarize this page”, “Check a claim”, or “Find related sources”. A starter fills an editable draft. For a useful comparison, name the criteria: “Compare these proposals on cost, evidence, and implementation effort.”

Read the answer and open its source cards as tabs. **Activity** shows recent reported actions while the agent works, retaining every running tool and opening its task list. Choose **Details** for all actions; choose a tool's **Result** for output or a diff. Checkmarks mean completed actions, spinners mean running actions, and red marks mean failures. Before any action is reported, the view says it is preparing the next step; it does not invent progress. The input folds down while the page has the keyboard, leaving more room for reading. Click it to reveal the model and reasoning controls again.

## Across sources

Choose **Expand conversation** for a longer conversation. The expanded composer sends your words without automatically attaching the current page. Choose **Attach current page** to pin it; a pinned page stays attached in either layout. Selected-text attachments also stay with the draft. Use **Recent conversations** to resume a chat; the draft stays with the agent when switching between layouts.

The status row distinguishes **Working**, **Needs your answer**, **Needs your approval**, **Interrupted**, **Ready to continue**, and **Finished**. **Answer** focuses the input; permission buttons remain in the request below. **Continue** prepares a follow-up without sending it. **Follow up** focuses the input after a finished turn. A failed turn offers **Reconnect** rather than silently repeating actions.

Expand **Agent pages** to see pages Codegraff currently has open. Choose a row to open a copy in your tabs, with the browser's sign-ins. Updates to this list never switch tabs or take keyboard focus. Sources that were only read and immediately closed remain in the activity and source links instead. Starting or switching conversations clears the previous conversation's open agent pages; reconnecting preserves them.

While a run is working, sending a follow-up adds it to the queue. **Stop** pauses that queue. Sending another message or choosing **Send now** is a deliberate continuation.

## Recovering and reporting

If a run is unresponsive, open **Conversation options → Reconnect**. Reconnecting ends the old process, restores the saved session, and holds queued messages. If the session is unavailable, browse supplies the visible transcript before the next prompt. Actions already performed are not undone, and the old task is not automatically repeated.

Use the flag beneath an answer, **Conversation options → Report an agent problem**, or `/feedback` followed by a description. Choose the problem type, describe what happened and what you expected, then copy the report or review a GitHub draft. The draft contains the description and build details; it does not collect the chat or page. Submission happens on GitHub.

## A feedback-to-fix workflow

The reporting entry point is implemented. Automatic repair is a separate next stage: reproduce a submitted report in an isolated bench world, determine whether browse or graff owns the cause, fix it on a branch, run the relevant checks, and prepare a pull request for review. Graff reports and upstream fixes follow this repository's codegraff issue policy.

## Validation

After `./build.sh debug`, run `python3 tests/agent-recovery.py`. It starts a hidden, separate test world with a scripted ACP agent and runs 14 checks covering keyboard focus, period-shortcut routing and punctuation protection, recovery, queue ordering, local feedback routing, selected-text review and source identity, password exclusion, pinned and excluded context, task states, and agent-page navigation. It sends no prompts to a real model.
