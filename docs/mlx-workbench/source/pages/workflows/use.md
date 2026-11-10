# Use models

**Use** keeps conversations and model tasks in the workbench. Select a ready
model in Library and choose **Use model**, or choose **Use…** beside a running
server in Run. **New** starts another work session with a ready model.

## Conversations

Choose a running connection in **Server**, enter a message and choose **Send**
(⌘Return). Each request includes the conversation's completed turns. History
is stored locally and reopens without relying on a server response cache.

If no server is available, **Start server…** opens the existing Run surface.
Preview and confirm the server there, then choose **Return to Use**. A single
matching running server is selected; choose a connection when several match. Opening a conversation does not start a server or download weights.
**Manage server…** opens the same controls for memory policy and inference settings.

The server's inference API key is read from Workbench's credential store.
A missing key or changed server refuses the request and retains the draft.
A replacement process on the same port is a different connection; select it
explicitly before continuing. Every recorded reply keeps its original server
identity and request settings.

**Request settings** controls the response token limit, temperature and system
instructions. Apply them to the conversation, or save them as defaults for new
conversations. The server retains its own inference settings and memory policy.
These controls do not change a running server's configuration.

Vision servers offer **Image** for PNG and JPEG inputs. Images are verified and
kept in the app's input folder, with one copy per content digest. Follow-up
messages can reuse them after the original file moves. Each image is at most
8 MB; a conversation request can include at most 8 MB of image bytes across its
current context. Up to four images can accompany one message. Text-only servers
do not offer image input.

## Stop, recover and export

**Stop waiting** (⌘.) closes only the conversation's owned request. The server
may still be finishing inference; Workbench does not report server cancellation
without confirmation. Partial text remains available. **Try again** is an
explicit new request and preserves any new unsent draft.

Interrupted replies reopen as interrupted. Reopening history never resubmits
inference. Workbench saves a pending turn before sending it and checkpoints
streamed text. Quitting flushes the latest draft; a save failure offers keeping
the app open or quitting without saving.

Use the export menu for Markdown or JSON. Exports include conversation text,
reply states, server identity and image metadata; image files remain in the
app's input folder. Export can recover a draft even when history cannot be saved.
A save error offers **Save again** and keeps unsaved text visible.

Conversations support 100 turns and 8 MB of recorded text, with prompts of up to
32 KB. When a limit is reached, export the work and start a new conversation.
Partial or interrupted replies are not silently added to the next request's
conversation context. Replies do not establish verification or comparison results.

## Model tasks

Classification, embeddings, speech, music, image, video and 3D models use their
existing task forms and artifact viewers. A vision-language model can also open
**New model task** from the New menu. **Run on** selects a running typed endpoint
or a one-off run. The selected source is retained with the work session.

Jobs and artifacts remain in their engine-owned store. After restart, select a
recorded job to inspect, play or export its verified output. A missing model does
not remove recorded results. [Local inference tasks](library.md#local-inference-tasks)
describes cancellation, input reuse and unconfirmed-submission recovery.

History appears beside the work at wide sizes. At smaller sizes, **Work sessions**
opens it separately so the message editor and Send or Stop action remain visible.
