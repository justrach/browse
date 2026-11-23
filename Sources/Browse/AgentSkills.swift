import Foundation

/// Dia-style inline `/skills` invoked directly from the Agent composer or `⌘K`
/// switcher, unified with user-saved `AgentTask` entries (`agent-tasks.json`).
struct DiaSkill: Identifiable, Equatable {
    let id: String
    /// Lowercase slash trigger without leading `/` (e.g. `"summarize"`).
    let slug: String
    let title: String
    let description: String
    let icon: String
    let prompt: String
    let isCustom: Bool

    /// Built-in Dia skills available out of the box in every session.
    static let builtIn: [DiaSkill] = [
        DiaSkill(
            id: "skill-summarize",
            slug: "summarize",
            title: "Summarize",
            description: "Concise executive summary & key takeaways of this page",
            icon: "text.alignleft",
            prompt: "Summarize the attached page concisely. Lead with a 1-sentence TL;DR, followed by the 3–5 most important takeaways with concrete numbers or facts. Skip filler.",
            isCustom: false
        ),
        DiaSkill(
            id: "skill-factcheck",
            slug: "factcheck",
            title: "Fact-check",
            description: "Verify claims on this page against primary sources",
            icon: "checkmark.shield",
            prompt: "Fact-check the main claims on the attached page using primary sources. List each key claim, whether it holds up (Supported / Mixed / Unsupported), and include source links.",
            isCustom: false
        ),
        DiaSkill(
            id: "skill-explain",
            slug: "explain",
            title: "Explain simply",
            description: "Break down the page in plain language with examples",
            icon: "lightbulb",
            prompt: "Explain the core idea of the attached page in clear, plain language. Define any jargon and give 1–2 concrete real-world examples.",
            isCustom: false
        ),
        DiaSkill(
            id: "skill-compare",
            slug: "compare",
            title: "Compare tabs",
            description: "Compare this page & @-mentioned tabs side-by-side",
            icon: "rectangle.split.2x1",
            prompt: "Compare the attached page and any @-mentioned tabs side-by-side in a concise Markdown table covering the key differences, trade-offs, pricing/specs (if applicable), and a clear bottom-line recommendation.",
            isCustom: false
        ),
        DiaSkill(
            id: "skill-reply",
            slug: "reply",
            title: "Draft reply",
            description: "Write a crisp, natural reply to this email or thread",
            icon: "arrowshape.turn.up.left",
            prompt: "Draft a concise, natural, ready-to-send reply to the email, message, or post shown on the attached page. Match the context and tone without sounding robotic.",
            isCustom: false
        ),
        DiaSkill(
            id: "skill-extract",
            slug: "extract",
            title: "Extract data",
            description: "Pull structured tables, dates, links, or action items",
            icon: "tablecells",
            prompt: "Extract the key structured information from the attached page — tables, dates, prices, specs, links, or action items — formatted cleanly in Markdown so it's easy to scan or copy.",
            isCustom: false
        ),
        DiaSkill(
            id: "skill-translate",
            slug: "translate",
            title: "Translate",
            description: "Translate this page or passage cleanly into English",
            icon: "globe",
            prompt: "Translate the main content of the attached page cleanly and naturally into English (or the target language specified), preserving formatting and nuance.",
            isCustom: false
        ),
    ]

    /// Converts saved `AgentTask` items into `/slug` inline skills.
    static func all(customTasks: [AgentTask]) -> [DiaSkill] {
        var list = builtIn
        var used = Set(list.map(\.slug))
        for task in customTasks {
            let slug = makeSlug(from: task.title)
            guard !slug.isEmpty, used.insert(slug).inserted else { continue }
            list.append(DiaSkill(
                id: "custom-\(task.id.uuidString)",
                slug: slug,
                title: task.title,
                description: task.prompt.replacingOccurrences(of: "\n", with: " "),
                icon: "sparkles",
                prompt: task.prompt,
                isCustom: true
            ))
        }
        return list
    }

    static func makeSlug(from title: String) -> String {
        let lower = title.lowercased()
        var out = ""
        var prevDash = false
        for scalar in lower.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                prevDash = false
            } else if !out.isEmpty && !prevDash {
                out.append("-")
                prevDash = true
            }
        }
        while out.last == "-" { out.removeLast() }
        return String(out.prefix(28))
    }

    /// Expands a leading `/skill [optional extra instructions]` into the full
    /// prompt sent to the agent. Returns `nil` if `text` is not a known skill.
    static func expand(_ text: String, customTasks: [AgentTask]) -> (skill: DiaSkill, prompt: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let rest = trimmed.dropFirst()
        let parts = rest.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let first = parts.first else { return nil }
        let slug = String(first).lowercased()
        guard let skill = all(customTasks: customTasks).first(where: { $0.slug == slug }) else { return nil }
        let extra = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let combined = extra.isEmpty ? skill.prompt : "\(skill.prompt)\n\nAdditional focus: \(extra)"
        return (skill, combined)
    }
}

/// YouTube video context extraction and clickable `[MM:SS]` timestamp seeking
/// for Dia-style video Q&A.
enum YouTubeHelper {
    static let seekScheme = "browse-seek"

    static func isYouTubeWatch(_ url: URL?) -> Bool {
        guard let host = url?.host()?.lowercased() else { return false }
        if host == "youtu.be" { return true }
        guard host == "youtube.com" || host.hasSuffix(".youtube.com") else { return false }
        let path = url?.path ?? ""
        return path.hasPrefix("/watch") || path.hasPrefix("/shorts/") || path.hasPrefix("/live/")
    }

    /// Runs inside the page to extract live playback timestamp, duration,
    /// title, channel, description, and any caption track URL/text without
    /// modifying the DOM.
    static let contextScript = """
    (async () => {
      try {
        const fmt = (sec) => {
          sec = Math.max(0, Math.floor(sec || 0));
          const h = Math.floor(sec / 3600);
          const m = Math.floor((sec % 3600) / 60);
          const s = sec % 60;
          const pad = (n) => String(n).padStart(2, '0');
          return h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${m}:${pad(s)}`;
        };
        const video = document.querySelector('video');
        const cur = video ? video.currentTime : 0;
        const dur = video && isFinite(video.duration) ? video.duration : 0;
        const mp = document.getElementById('movie_player');
        const pr = (mp && typeof mp.getPlayerResponse === 'function' ? mp.getPlayerResponse() : null) || window.ytInitialPlayerResponse;
        const details = pr && pr.videoDetails ? pr.videoDetails : {};
        const title = details.title || document.title || '';
        const author = details.author || '';
        const desc = (details.shortDescription || '').slice(0, 1500);
        let transcript = '';
        const tracks = pr && pr.captions && pr.captions.playerCaptionsTracklistRenderer && pr.captions.playerCaptionsTracklistRenderer.captionTracks;
        if (Array.isArray(tracks) && tracks.length > 0) {
          const track = tracks.find(t => (t.languageCode || '').startsWith('en')) || tracks[0];
          if (track && track.baseUrl) {
            try {
              const url = track.baseUrl + (track.baseUrl.includes('?') ? '&' : '?') + 'fmt=json3';
              const res = await fetch(url);
              if (res.ok) {
                const json = await res.json();
                const lines = [];
                for (const ev of (json.events || [])) {
                  if (!ev.segs) continue;
                  const txt = ev.segs.map(s => s.utf8 || '').join('').replace(/\\s+/g, ' ').trim();
                  if (!txt) continue;
                  const ts = fmt((ev.tStartMs || 0) / 1000);
                  lines.push(`[${ts}] ${txt}`);
                  if (lines.length >= 260) break;
                }
                transcript = lines.join('\\n').slice(0, 18000);
              }
            } catch (_) {}
          }
        }
        const out = [
          `YouTube Video: ${title}`,
          author ? `Channel: ${author}` : '',
          dur > 0 ? `Playback: [${fmt(cur)}] / [${fmt(dur)}]` : (cur > 0 ? `Playback: [${fmt(cur)}]` : ''),
          'Tip: Cite timestamps in [MM:SS] format so the user can click them to seek the video directly.',
          desc ? `\\nDescription:\\n${desc}` : '',
          transcript ? `\\nTranscript:\\n${transcript}` : ''
        ].filter(Boolean).join('\\n');
        return out;
      } catch (_) {
        return '';
      }
    })();
    """

    static func seekScript(seconds: Int) -> String {
        """
        (() => {
          const v = document.querySelector('video');
          if (!v) return false;
          v.currentTime = \(max(0, seconds));
          if (v.paused) { v.play().catch(() => {}); }
          return true;
        })();
        """
    }

    /// Rewrites standalone `[MM:SS]` or `[H:MM:SS]` tokens in Markdown text
    /// into clickable `[MM:SS](browse-seek://<seconds>)` links, skipping
    /// anything already inside an inline code span or Markdown link target.
    static func linkTimestamps(in text: String) -> String {
        guard text.contains("[") && text.contains(":") else { return text }
        let chars = Array(text)
        var out = ""
        out.reserveCapacity(text.count + 32)
        var i = 0
        var inCode = false
        while i < chars.count {
            if chars[i] == "`" {
                inCode.toggle()
                out.append(chars[i])
                i += 1
                continue
            }
            if !inCode && chars[i] == "[" {
                if let close = chars[(i + 1)...].firstIndex(of: "]") {
                    let inner = String(chars[(i + 1)..<close])
                    let nextIdx = close + 1
                    let alreadyLinked = nextIdx < chars.count && chars[nextIdx] == "("
                    if !alreadyLinked, let seconds = parseTimestamp(inner) {
                        out += "[\(inner)](\(seekScheme)://\(seconds))"
                        i = nextIdx
                        continue
                    }
                }
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    static func parseTimestamp(_ raw: String) -> Int? {
        let parts = raw.split(separator: ":")
        guard parts.count == 2 || parts.count == 3 else { return nil }
        guard parts.allSatisfy({ !$0.isEmpty && $0.count <= 2 && $0.allSatisfy(\.isNumber) }) else { return nil }
        let nums = parts.compactMap { Int($0) }
        guard nums.count == parts.count else { return nil }
        if nums.count == 2 {
            guard nums[1] < 60 else { return nil }
            return nums[0] * 60 + nums[1]
        } else {
            guard nums[1] < 60 && nums[2] < 60 else { return nil }
            return nums[0] * 3600 + nums[1] * 60 + nums[2]
        }
    }
}
