# Perch — ideas for later (from the user, 2026-11-17)

Do NOT implement until the round-2 changes (docs/REDESIGN-2.md) are installed and tested on the Watch.

1. **Launch intro**: a short splash/intro animation like X's, shown on a cold launch only (not when
   the app resumes from the background).
2. **Loading skeletons**: YouTube-style placeholder skeletons (shimmering grey shapes for avatar,
   name, text lines, media) while posts/images are not loaded yet.
3. **Save posts offline**: save a post together with its attachments (images, video) locally.
   - A menu category "Saved / Offline" listing them.
   - Lists like Likes/Bookmarks reuse the saved copy instead of fetching it again; when online only
     the fresh counts / new comments are fetched.
   - Saving (downloading attachments) must also continue/complete in the background.
4. **Offline-first app**: the whole app must be usable offline from cache (feed, posts, profiles,
   images), with proper offline mechanisms (clear offline state, queued actions, no error walls).
5. **Cleaner feed**: filter ads / promoted / "global" filler, keep only posts that match the user's
   interests (if feasible with what X returns).
6. **Faster fetching + polish**:
   - Measure network speed while the app is used and pick one of ~3 attachment-prefetch strategies
     by speed (or a more practical adaptive approach); make it fast.
   - Overall improvements to caching, smoothness, animations, buttons and effects.
