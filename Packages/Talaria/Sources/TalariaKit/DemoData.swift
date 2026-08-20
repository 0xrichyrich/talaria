import Foundation

/// Demo roster and content, ported verbatim from the design prototype's
/// `hermes-data.js`. Backs the onboarding "Explore with demo data" path and
/// gives App Review a full experience without a running gateway.
public enum DemoData {

    public static let bots: [Bot] = [
        Bot(id: "researcher", job: "Papers & citations", shape: .hexagon, hue: .violet,
            status: .working, task: "Reading arXiv 2508.11402", minutesElapsed: 4,
            preview: "Digest ready — 6 papers worth your time.", previewTime: "07:02", unread: 0,
            description: "Reads the firehose so you only skim the signal."),
        Bot(id: "comms", job: "Drafts & posts", shape: .diamond, hue: .pink,
            status: .working, task: "Drafting launch thread", minutesElapsed: 12,
            preview: "@you which screenshot for the launch post?", previewTime: "now", unread: 2,
            mentionsYou: true, description: "Drafts in your voice; never posts without a seal."),
        Bot(id: "inbox", job: "Email triage", shape: .squircle, hue: .amber,
            status: .approval, task: "Waiting on your sign-off", minutesElapsed: 0,
            preview: "Drafted a reply to Sarah — needs your sign-off.", previewTime: "08:14", unread: 1,
            description: "Keeps the inbox at zero; asks before anything leaves."),
        Bot(id: "ops", job: "Server watchdog", shape: .triangle, hue: .green,
            preview: "caddy restarted cleanly. Uptime 14d 03h.", previewTime: "06:40",
            description: "Watches the boxes. Restarts, backups, certs."),
        Bot(id: "scout", job: "Leads & listings", shape: .pentagon, hue: .blue,
            preview: "3 new leads scored 80+ this week.", previewTime: "yest",
            description: "Scores leads and listings while you sleep."),
        Bot(id: "hermes", job: "General agent", shape: .circle, hue: .teal,
            preview: "Ready when you are.", previewTime: "Mon",
            description: "The default profile. Good at everything, pinned to nothing."),
    ]

    public static let chats: [String: [ChatMessage]] = [
        "researcher": [
            ChatMessage(author: .system, text: "Routine · Morning digest · ran 07:00"),
            ChatMessage(author: .bot, time: "07:02",
                        text: "Morning. 6 papers since yesterday worth your time — top pick is on recurrent depth for test-time scaling. The sparse-routing survey is solid too.",
                        card: .papers([
                            .init(title: "Scaling Test-Time Compute with Recurrent Depth",
                                  meta: "Geiping et al. · 42 pages",
                                  summary: "Latent reasoning without longer context. Strongest result of the batch."),
                            .init(title: "A Survey of Sparse Expert Routing",
                                  meta: "Liu, Tran · survey",
                                  summary: "Good taxonomy; skim §4 on load-balancing losses."),
                            .init(title: "PyramidKV: Cache Compression",
                                  meta: "Chen et al.",
                                  summary: "2–4× KV memory cut with minor quality loss."),
                        ])),
            ChatMessage(author: .user, time: "08:31", text: "Anything else on KV-cache compression?"),
        ],
        "inbox": [
            ChatMessage(author: .system, text: "Routine · Inbox sweep · ran 08:00"),
            ChatMessage(author: .bot, time: "08:14",
                        text: "Swept 41 emails. 38 archived, 2 flagged for later, 1 needs you: Sarah is asking about the invoice timeline. I drafted a reply.",
                        card: .approvalRef("ap1")),
        ],
        "comms": [
            ChatMessage(author: .bot, time: "07:42",
                        text: "@you Launch thread is drafted — 4 posts, ends on the roster demo. Which screenshot leads? [1] terminal session, [2] bot roster, [3] voice orb."),
        ],
    ]

    public static let quickReplies: [String: [String]] = [
        "researcher": ["Add them to tomorrow’s digest", "Just links, please"],
        "comms": ["Lead with the roster", "Terminal — keep it raw"],
        "inbox": ["Looks good, send it", "Soften the second line"],
    ]

    public static let cannedReplies: [String: String] = [
        "researcher": "Two more queued: PyramidKV (above) and a weaker MLA variant. I’ll fold full summaries into tomorrow’s 07:00 digest.",
        "comms": "Roster it is. Thread scheduled for 10:00 — it’s in your approvals.",
        "inbox": "Sent. I’ll watch for her reply and file the invoice when it lands.",
        "default": "On it. I’ll report back here when it’s done.",
    ]

    public static let approvals: [Approval] = [
        Approval(id: "ap1", botID: "inbox", kind: .email, title: "Send email reply",
                 target: "sarah.chen@meridian.co", subject: "Re: Invoice timeline",
                 body: "Hi Sarah — the revised invoice goes out Thursday with net-30 terms as discussed. I’ve attached the updated SOW so the numbers match.",
                 why: "Outbound email always requires sign-off", age: "12m"),
        Approval(id: "ap2", botID: "ops", kind: .command, title: "Run shell command",
                 target: "homelab · /srv", subject: "systemctl restart caddy",
                 body: "Cert renewal hung on the ACME challenge; a clean restart clears the stale lock. Zero-downtime reload attempted first and failed.",
                 why: "Command touches a system service", age: "26m"),
        Approval(id: "ap3", botID: "comms", kind: .post, title: "Publish launch thread",
                 target: "x.com · @anderson", subject: "4-post thread · scheduled 10:00",
                 body: "Meet the roster: six agents, one gateway. Post 1 leads with the bot roster screen, ends on a call to the repo.",
                 why: "Public posts always require sign-off", age: "38m"),
    ]

    public static let routines: [Routine] = [
        Routine(id: "r1", botID: "researcher", name: "Morning digest", schedule: "Daily · 07:00",
                next: "in 22h 18m", last: "ran today · 6 papers", isOn: true),
        Routine(id: "r2", botID: "researcher", name: "Weekly deep-dive", schedule: "Mon · 08:00",
                next: "in 6d 23h", last: "ran Mon · recurrent depth", isOn: true),
        Routine(id: "r3", botID: "inbox", name: "Inbox sweep", schedule: "Every 2h · 08–20",
                next: "in 1h 46m", last: "ran 08:00 · 41 handled", isOn: true),
        Routine(id: "r4", botID: "ops", name: "Nightly backup verify", schedule: "Daily · 03:00",
                next: "in 18h 46m", last: "ran 03:00 · 42 GB ok", isOn: true),
        Routine(id: "r5", botID: "scout", name: "Lead scan", schedule: "Fri · 09:00",
                next: "in 4d 0h", last: "ran Fri · 3 scored 80+", isOn: false),
    ]

    public static let activity: [ActivityDay] = [
        ActivityDay(day: "Today", items: [
            ActivityItem(time: "08:14", botID: "inbox", kind: .approval,
                         text: "Needs approval — reply to Sarah Chen", subtext: "Re: Invoice timeline", pending: true),
            ActivityItem(time: "07:42", botID: "comms", kind: .mention,
                         text: "Mentioned you in its chat", subtext: "“which screenshot for the launch post?”"),
            ActivityItem(time: "07:00", botID: "researcher", kind: .routine,
                         text: "Routine finished — Morning digest", subtext: "6 papers · 2 flagged must-read"),
            ActivityItem(time: "06:40", botID: "ops", kind: .task,
                         text: "Long task done — backup verified", subtext: "42 GB · 18m · checksums clean"),
            ActivityItem(time: "03:12", botID: "gateway", kind: .gateway,
                         text: "homelab offline 6m — recovered", subtext: "tailscale route flapped, self-healed"),
        ]),
        ActivityDay(day: "Yesterday", items: [
            ActivityItem(time: "18:03", botID: "comms", kind: .task,
                         text: "Blog draft ready for review", subtext: "“Six agents, one gateway” · 1,200 words"),
            ActivityItem(time: "09:00", botID: "scout", kind: .routine,
                         text: "Routine finished — Lead scan", subtext: "3 leads scored 80+"),
            ActivityItem(time: "08:52", botID: "inbox", kind: .approved,
                         text: "You approved — intro email to Kade", subtext: "sent 08:53 · reply received"),
        ]),
    ]

    public static let agentInbox: [A2AMessage] = [
        A2AMessage(fromBotID: "comms", toBotID: "researcher", time: "07:44",
                   text: "Need the strongest benchmark number from today’s digest for the launch thread."),
        A2AMessage(fromBotID: "researcher", toBotID: "comms", time: "07:45",
                   text: "61.3% SWE-bench Verified, single pass. Cite the harness commit — it’s in my digest notes."),
        A2AMessage(fromBotID: "ops", toBotID: "all", time: "06:41",
                   text: "Deploy window tonight 22:00–23:00. Hold merges to main; I’ll run the checklist."),
        A2AMessage(fromBotID: "scout", toBotID: "inbox", time: "yest",
                   text: "Kade replied — warm. Draft an intro for Anderson to approve in the morning."),
    ]

    public static let connections: [GatewayConnection] = [
        GatewayConnection(id: "homelab", name: "homelab", kind: .tailscale,
                          address: "100.84.12.9:9119", state: .connected, ping: "12ms", botCount: 6),
        GatewayConnection(id: "mbp", name: "MacBook Pro", kind: .lan,
                          address: "192.168.1.24:9119", state: .asleep, ping: "—", botCount: 2),
        GatewayConnection(id: "cloud", name: "Hermes Cloud", kind: .cloud,
                          address: "org: anderson", state: .connected, ping: "84ms", botCount: 2),
    ]

    public static let notificationPrefs: [NotificationPref] = [
        NotificationPref(id: "p1", kind: .approval, name: "Bot needs approval",
                         subtitle: "Time-sensitive — bots block on you", isOn: true, isCritical: true),
        NotificationPref(id: "p2", kind: .response, name: "Agent reply ready",
                         subtitle: "A completed answer opens its stored session", isOn: true),
        NotificationPref(id: "p3", kind: .routine, name: "Routine finished",
                         subtitle: "Digest, sweeps, scheduled runs", isOn: true),
        NotificationPref(id: "p4", kind: .mention, name: "Bot mentioned you",
                         subtitle: "@you in any bot’s chat", isOn: true),
        NotificationPref(id: "p5", kind: .task, name: "Long task done",
                         subtitle: "Anything over 10 minutes", isOn: true),
        NotificationPref(id: "p6", kind: .gateway, name: "Gateway offline",
                         subtitle: "A connection drops or recovers", isOn: true),
    ]

    public static let sessions: [String: [SessionSummary]] = [
        "researcher": [
            SessionSummary(id: "s-8821", title: "KV-cache follow-up", when: "today 08:31", messageCount: 14),
            SessionSummary(id: "s-8790", title: "Morning digest · routine run", when: "today 07:00", messageCount: 3),
            SessionSummary(id: "s-8654", title: "Recurrent-depth deep dive", when: "Mon 09:12", messageCount: 41),
        ],
        "inbox": [
            SessionSummary(id: "s-8815", title: "Sarah Chen · invoice thread", when: "today 08:14", messageCount: 9),
            SessionSummary(id: "s-8688", title: "Intro email to Kade", when: "yest 08:52", messageCount: 6),
        ],
        "comms": [
            SessionSummary(id: "s-8809", title: "Launch thread draft", when: "today 07:42", messageCount: 22),
            SessionSummary(id: "s-8571", title: "Blog: Six agents, one gateway", when: "yest 18:03", messageCount: 17),
        ],
        "ops": [
            SessionSummary(id: "s-8801", title: "caddy cert renewal", when: "today 06:40", messageCount: 11),
            SessionSummary(id: "s-8620", title: "Backup verify · routine run", when: "today 03:00", messageCount: 4),
        ],
        "default": [
            SessionSummary(id: "s-000", title: "First conversation", when: "new", messageCount: 0),
        ],
    ]

    public static let artifacts: [Artifact] = [
        Artifact(id: "a1", botID: "comms", kind: .image, title: "launch-hero.png",
                 meta: "1920×1080 · thread post 1", when: "07:41"),
        Artifact(id: "a2", botID: "researcher", kind: .file, ext: "MD", title: "digest-2026-08-17.md",
                 meta: "6 papers · 2 must-read", when: "07:00"),
        Artifact(id: "a3", botID: "ops", kind: .file, ext: "TXT", title: "backup-verify.log",
                 meta: "42 GB · checksums clean", when: "03:12"),
        Artifact(id: "a4", botID: "comms", kind: .image, title: "roster-screen.png",
                 meta: "1170×2532 · thread post 2", when: "yest"),
        Artifact(id: "a5", botID: "scout", kind: .file, ext: "CSV", title: "leads-aug-w3.csv",
                 meta: "3 scored 80+", when: "Fri"),
        Artifact(id: "a6", botID: "researcher", kind: .link, title: "arxiv.org/abs/2508.11402",
                 meta: "Recurrent depth · cited in digest", when: "07:02"),
    ]

    public static let memory: [String: BotMemory] = [
        "researcher": BotMemory(skillCount: 4, memoryCount: 12, recent: [
            "You skim digests before 07:30",
            "Cite the eval-harness commit with benchmarks",
            "PyramidKV flagged must-read",
        ]),
        "inbox": BotMemory(skillCount: 3, memoryCount: 9, recent: [
            "Sarah Chen = invoice contact at Meridian",
            "Never send before you approve",
            "Archive newsletters silently",
        ]),
        "comms": BotMemory(skillCount: 3, memoryCount: 8, recent: [
            "Your voice: short, concrete, no hype",
            "Threads end on a call to the repo",
            "Post window 10:00–11:00",
        ]),
        "ops": BotMemory(skillCount: 5, memoryCount: 11, recent: [
            "Deploy window 22:00–23:00",
            "Prefer zero-downtime reload first",
            "Backups verify at 03:00",
        ]),
        "default": BotMemory(skillCount: 2, memoryCount: 3, recent: [
            "Fresh profile — memory builds as you work",
        ]),
    ]

    public static let contextMeter: [ContextSegment] = [
        ContextSegment(label: "system prompt", percent: 9),
        ContextSegment(label: "tool definitions", percent: 12),
        ContextSegment(label: "skills", percent: 6),
        ContextSegment(label: "memory", percent: 8),
        ContextSegment(label: "conversation", percent: 31),
    ]

    public static let models: [String] = [
        "Hermes-4-405B (default)", "Hermes-4-70B", "nemotron-3-ultra · local", "grok-4 · api",
    ]

    public static let skills: [String] = [
        "web-research", "email", "shell", "calendar", "image-gen", "browser",
    ]
}
