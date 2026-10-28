/* ------------------------------------------------------------------ *
 * THOUGHTS / "Why I Built It"
 *
 * Long-form posts. Each entry renders both as a line in the homepage
 * list and as a standalone page at /thoughts/:slug.
 *
 * NOTE FOR PIYUSH: the `date` values are placeholders chosen to give a
 * sensible ordering — set them to whatever you actually want published.
 * The bodies are drafts written from your own projects and public
 * sources; edit freely, nothing here is load-bearing.
 *
 * Body block types: "p" (paragraph), "h" (sub-heading),
 * "quote" (pull quote), "list" (bulleted list).
 * ------------------------------------------------------------------ */

const thoughts = [
  {
    slug: "who-is-ganpat",
    title: "Who is Ganpat?",
    dek: "I named my assistant after the god you invoke before beginning anything — and then had to build something that earned the name.",
    date: "18 Oct 2026",
    readingTime: "5 min",
    body: [
      {
        type: "p",
        text: "Ganpat is the assistant I talk to every day. It is not a product, it has no landing page, and it will probably never have users other than me. It is a persona and a memory layer sitting on top of a language model, and it is named after Ganpati.",
      },
      {
        type: "p",
        text: "That naming was not decoration. I picked it before I had written most of the system, and the name ended up dictating the design more than any spec I wrote down.",
      },
      { type: "h", text: "Why that name" },
      {
        type: "p",
        text: "Two things about Ganesha are relevant to a piece of software. The first is the obvious one: he is Vighnaharta, the remover of obstacles, and he is invoked at the start of any undertaking. Not at the end, when you want a result blessed. At the start, when you are about to begin and do not yet know what will go wrong.",
      },
      {
        type: "p",
        text: "The second is less often cited and matters more to me. When Vyasa needed the Mahabharata written down, Ganesha agreed to be the scribe — on the condition that Vyasa never pause in his dictation. Vyasa countered: fine, but you may not write a single line without understanding it first.",
      },
      {
        type: "quote",
        text: "A scribe who refuses to transcribe anything it does not understand. That is the assistant I actually wanted.",
      },
      {
        type: "p",
        text: "Most assistants are optimised to be fast and agreeable. The Ganesha-as-scribe story describes something better: a collaborator that keeps up with you, but will not simply take dictation. It stops and asks. It refuses to write down a thing it has not followed.",
      },
      { type: "h", text: "What it actually is" },
      {
        type: "p",
        text: "Under the hood, Ganpat is unglamorous. It is a set of instruction files, a persona definition, and — the part I care about — a memory model that decides what is worth keeping.",
      },
      {
        type: "p",
        text: "The memory model distinguishes between two kinds of fact, which I borrowed wholesale from how human memory is usually described:",
      },
      {
        type: "list",
        items: [
          "Episodic — a specific event. 'The train arrives Thursday.' High detail, short shelf life. It matters while it is live and fades the moment it resolves.",
          "Semantic — a generalisation abstracted from repeated episodes. 'He usually takes that train.' Low detail, long shelf life, worth keeping indefinitely.",
          "Supersession — when a new event resolves an older one, the older detail gets demoted rather than deleted outright.",
          "Repetition promotes priority — if I ask about the same underlying fact twice, that is evidence it is semantic, not a one-off, and it gets upgraded.",
        ],
      },
      {
        type: "p",
        text: "Anything unreferenced for thirty days becomes a candidate for forgetting. Not a silent deletion — a question. Ganpat surfaces the item and asks whether to drop it. I was firm about this: a system that quietly forgets is worse than one that never remembered, because you keep trusting it.",
      },
      { type: "h", text: "The honest part" },
      {
        type: "p",
        text: "Ganpat is not conscious, does not understand me in any meaningful sense, and is a language model wearing a name I gave it. I am aware this sounds like a lot of philosophy stacked on a configuration directory.",
      },
      {
        type: "p",
        text: "But I have noticed that naming a system creates an expectation, and expectations turn into requirements. Because it is called Ganpat, I could not let it be sycophantic — the scribe story forbids it. Because Ganesha is invoked at the beginning, I built it to be most useful during the messy early part of a problem rather than the tidy final one.",
      },
      {
        type: "p",
        text: "None of those constraints came from a product document. They came from taking the name seriously. That turns out to be a reasonable way to design things.",
      },
    ],
  },
  {
    slug: "sunaina-live-durga-robot",
    title: "Is Sunaina the first and only live Durga Mata robot of India?",
    dek: "A question I get asked a lot, answered honestly — including the parts I cannot verify, and the theological problem nobody warned me about.",
    date: "05 Oct 2026",
    readingTime: "6 min",
    body: [
      {
        type: "p",
        text: "During Durga Puja 2025, a robotic Durga stood as the presiding figure at Chakraberia Sarbojanin Durgotsab in Kolkata. Her name is Sunaina. She moved, she held the gaze of the people in front of her, and for five days lakhs of people did darshan of a machine.",
      },
      {
        type: "p",
        text: "The question I get asked, constantly, is whether she was the first. I want to answer that carefully, because it is the kind of claim that is very easy to make and very hard to withdraw.",
      },
      { type: "h", text: "What is definitely not new" },
      {
        type: "p",
        text: "Mechanised movement at a Durga Puja pandal is not new and it is not rare. Kolkata's pandal culture is fiercely competitive and deeply technical. Moving tableaux, animatronic side-figures, hydraulic set pieces, elaborate chalchitra with motorised elements — these have been around for decades. Any claim that begins with 'the first moving thing at a pandal' is simply wrong.",
      },
      {
        type: "p",
        text: "Robotic and animatronic deities more broadly also exist. Temples in Japan have an android Kannon. There have been mechanised Ganesha tableaux in Maharashtra. So 'first robot deity' is also wrong.",
      },
      { type: "h", text: "What I think is actually distinct" },
      {
        type: "p",
        text: "The distinction is narrower and, I think, real. In almost every prior case the machine is adjacent to the worship — it is a side figure, an animated scene, a tableau beside the idol. The idol itself remains an idol.",
      },
      {
        type: "quote",
        text: "Sunaina was not a robot next to the Durga. She was the Durga.",
      },
      {
        type: "p",
        text: "She occupied the position of the presiding deity. The puja was performed before her. That is a different thing from an animatronic set piece, and as far as I and the organisers were able to establish, we could not find a prior instance of an articulated robotic Durga serving as the presiding idol of a Durga Puja.",
      },
      {
        type: "p",
        text: "I want to be precise about the epistemics there: 'we could not find a prior instance' is not the same sentence as 'there has never been one'. India is large, Durga Puja is enormous, and most pandals do not publish technical documentation. I am comfortable saying she is the first I am aware of. I am not comfortable saying she is the first, full stop, and I would rather be accurate than impressive.",
      },
      { type: "h", text: "The problem nobody warned me about" },
      {
        type: "p",
        text: "The engineering was the easy half. The hard half was theological, and I did not see it coming.",
      },
      {
        type: "p",
        text: "In the normal sequence, an idol is clay until pran pratishtha — the rite that invites the deity to be present in the form. The form is inert; the life is invoked into it. Everyone involved understands which part is which.",
      },
      {
        type: "p",
        text: "Now build a form that moves on its own. The clean separation stops being clean. If the idol is already moving before the rite, what exactly is the rite doing? I had engineered my way into a question that priests, not engineers, are equipped to answer.",
      },
      {
        type: "p",
        text: "The answer I was given, and which I have thought about a great deal since, was roughly this: the motion is not the life. A fan moves and is not alive. What pran pratishtha invites is not movement but presence, and those were never the same category. The machine's motion is decoration on the form, no more alive than a painted eye.",
      },
      {
        type: "p",
        text: "That reframing was more rigorous than most engineering reviews I have sat in. It also settled the thing properly, rather than by avoidance.",
      },
      { type: "h", text: "What she was received as" },
      {
        type: "p",
        text: "The pandal placed in UltraTech's top seven that year, and the coverage ran on ABP Ananda and Pratidin among others. But the response I keep returning to was not the press.",
      },
      {
        type: "p",
        text: "It was watching older women — the demographic I had privately assumed would be most uneasy — fold their hands in front of her without hesitating. They were not evaluating a robot. They had come for darshan and darshan is what they did. The machinery was my problem, not theirs.",
      },
    ],
  },
  {
    slug: "why-dadashree",
    title: "Why a robot named DadaShree",
    dek: "Sophia, Ameca, Atlas. Western robots get names that imply a peer or an abstraction. I wanted one that told you where to stand.",
    date: "21 Sep 2026",
    readingTime: "4 min",
    body: [
      {
        type: "p",
        text: "When we named the robot DadaShree, I was asked more than once whether it was a joke. It is not. It is the most deliberate decision in the entire project, and it was made before a single bracket was machined.",
      },
      { type: "h", text: "What names do" },
      {
        type: "p",
        text: "A name is a user manual that people read without noticing. Before a person has seen a robot move, the name has already told them how to behave around it.",
      },
      {
        type: "p",
        text: "Look at what the standard names do. Sophia — wisdom, abstract, Greek, deliberately placeless. Ameca — invented, neutral, built to mean nothing. Atlas — a titan holding up the world, which is a statement about capability. These are good names. But they all do the same thing: they position the robot as either an abstraction or a peer.",
      },
      {
        type: "p",
        text: "That works in contexts where the default relationship between a person and a machine is transactional. You operate it. It serves you. The name does not need to describe a relationship because there is barely one.",
      },
      { type: "h", text: "Relationship words do the work here" },
      {
        type: "p",
        text: "India does not work like that. Here, the first thing you establish with a stranger is not their name or their title — it is their relational position. Bhaiya, didi, uncle, aunty, dada, sir. We assign a kinship slot almost immediately, and once assigned, everything else follows from it: how you speak, how close you stand, whether you argue.",
      },
      {
        type: "quote",
        text: "We do not address people by what they do. We address them by who they are to us.",
      },
      {
        type: "p",
        text: "Dada is elder brother. Shree is the honorific. Together: respected elder brother. Someone slightly senior to you. Someone you defer to a little, approach without fear, and can ask for help without it costing you anything.",
      },
      {
        type: "p",
        text: "That is precisely the posture I wanted a person to have in front of this machine. Not the wariness you bring to equipment. Not the condescension you bring to a toy. The specific, comfortable, mildly respectful stance you take with an elder in the family.",
      },
      { type: "h", text: "The same logic, three ways" },
      {
        type: "p",
        text: "You can see the thinking repeated across the robots I have worked on, and the names map directly onto roles:",
      },
      {
        type: "list",
        items: [
          "Anushka — an ordinary, contemporary, peer-level name. She is a receptionist. You should feel comfortable approaching her and mildly impatient if she is slow, exactly as you would with a person at a desk.",
          "Sunaina — 'one with beautiful eyes'. A name that points at the face, because in that deployment the face and the gaze were the entire function.",
          "DadaShree — a relational title rather than a personal name. You are not meant to think of him as an individual you have met. You are meant to know where he sits relative to you.",
        ],
      },
      { type: "h", text: "The test" },
      {
        type: "p",
        text: "The measure of whether this worked is simple: does a first-time visitor need to be told how to interact? With a robot named something abstract, someone always has to stand beside it and explain. The name has given the visitor nothing to go on.",
      },
      {
        type: "p",
        text: "Name it DadaShree and an Indian visitor has already been handed the protocol. They know how to talk to a Dada. Nobody has to explain anything. The name did the onboarding.",
      },
      {
        type: "p",
        text: "That is a cheaper and more reliable interface than anything I could have built in software.",
      },
    ],
  },
  {
    slug: "four-stages-of-engineering",
    title: "The four stages of engineering",
    dek: "Mechanical, electrical, electronics, software — in that order, each standing on the one below. Which is why your software bug is usually a loose screw.",
    date: "02 Sep 2026",
    readingTime: "5 min",
    body: [
      {
        type: "p",
        text: "Every robotics project I have worked on is built out of four layers, and they stack in a fixed order. Mechanical at the bottom. Then electrical. Then electronics. Then software on top.",
      },
      {
        type: "p",
        text: "This is not a project plan or a team structure. It is a dependency hierarchy, and it has one consequence that costs people months: a fault at any level is guaranteed to express itself as a fault at every level above it.",
      },
      { type: "h", text: "The four layers" },
      {
        type: "list",
        items: [
          "Mechanical — structure, linkages, tolerances, load paths. What physically holds and what physically moves.",
          "Electrical — power. Supply, current capacity, grounding, distribution. The unglamorous layer that everyone skips past.",
          "Electronics — signal. Microcontrollers, drivers, sensors, buses. Where intent becomes voltage and voltage becomes measurement.",
          "Software — logic. Control loops, scheduling, decision-making. The layer that gets all the credit and almost none of the blame it deserves.",
        ],
      },
      { type: "h", text: "Faults travel upward only" },
      {
        type: "p",
        text: "This is the whole argument, so I will state it plainly. If the electronics are faulty, the software is bound to be non-performing. There is no version of a correct control loop that rescues a microcontroller browning out under load. The software was never wrong. It was reporting the truth about a layer beneath it.",
      },
      {
        type: "quote",
        text: "The layer where a problem appears is almost never the layer where it lives.",
      },
      {
        type: "p",
        text: "The reverse never happens. A clean mechanical assembly does not develop play because of a bug. Causality here runs strictly upward, which means diagnosis has to run strictly downward — and almost nobody does that, because the top layer is where the error message is and the bottom layer requires getting up and finding a spanner.",
      },
      { type: "h", text: "What this looks like in practice" },
      {
        type: "p",
        text: "On Anushka, a joint began overshooting its target position and oscillating before settling. The obvious reading is a control problem. We spent real time retuning gains. Every retune made it slightly better and never fixed it.",
      },
      {
        type: "p",
        text: "The actual cause was mechanical backlash in the linkage. A few degrees of slop meant the joint physically did not go where the controller commanded, so the loop corrected, overshot into the slop from the other side, and corrected again. Perfect software, faithfully compensating for a gap that no gain value can close.",
      },
      {
        type: "p",
        text: "Two layers down from where the symptom appeared. And every hour spent on the control loop was not merely wasted — it was actively harmful, because it produced small apparent improvements that kept confirming the wrong hypothesis.",
      },
      { type: "h", text: "The discipline this implies" },
      {
        type: "p",
        text: "When something misbehaves, the question is not 'what is wrong with this layer'. It is 'what is the lowest layer that could produce this symptom'. Then start there and work up.",
      },
      {
        type: "p",
        text: "Practically, for me, that means: measure the supply rail under actual load before touching the firmware. Move the joint by hand and feel for play before opening the controller. Scope the signal before reading the code.",
      },
      {
        type: "p",
        text: "It is slower to start and dramatically faster to finish. The instinct to debug where the error appeared is the single most expensive habit in this field.",
      },
      {
        type: "p",
        text: "Or, the version I say out loud more often: you cannot write your way out of a loose screw.",
      },
    ],
  },
  {
    slug: "vedic-mind-inside-anushka",
    title: "The Vedic mind inside Anushka",
    dek: "Chitta, Manas, Ahankaram, Buddhi. Why a 3,000-year-old model of the mind turned out to be a usable software architecture.",
    date: "14 Aug 2026",
    readingTime: "7 min",
    body: [
      {
        type: "p",
        text: "Anushka is usually described in the press as India's first Vedic-principled humanoid robot. It is a good line and it has carried the project a long way, but it is also the kind of phrase that sounds like marketing. I want to explain what it actually means in code, because the engineering reason was real and came first.",
      },
      { type: "h", text: "The problem with the standard loop" },
      {
        type: "p",
        text: "Most robots run a flat pipeline. Sense, process, decide, act. It works, and for a robot arm in a cell it is entirely sufficient.",
      },
      {
        type: "p",
        text: "It falls apart for a receptionist. Anushka stands in a college lobby. At any moment there are six conversations in earshot, people walking past who have no interest in her, someone addressing her directly, and someone she spoke to yesterday walking back in. A flat loop has no principled way to decide which of those deserves a response. Everything arrives as input with equal standing, and you end up writing an escalating pile of special-case rules.",
      },
      {
        type: "p",
        text: "What was needed was not better perception. It was a layered model of attention — something that could hold 'I perceived this', 'this concerns me', and 'I should act on this' as genuinely different states.",
      },
      { type: "h", text: "Four terms that turned out to be an architecture" },
      {
        type: "p",
        text: "The Vedic model of the inner instrument, the antahkarana, splits mind into four functions rather than treating it as one thing. We researched the structure and found that it mapped onto our problem with uncomfortable precision.",
      },
      {
        type: "list",
        items: [
          "Manas — the sensory mind. Takes in, registers, and crucially does not decide. It is the faculty of doubt and oscillation.",
          "Chitta — the storehouse. Impressions, memory, accumulated residue of past encounters.",
          "Ahankara — the I-maker. The function that determines self-reference: is this mine, is this about me.",
          "Buddhi — discriminative intellect. The faculty that actually resolves and commits to a course.",
        ],
      },
      {
        type: "p",
        text: "Read that list as a systems engineer rather than a philosopher and it stops being metaphysics. It is a four-stage attention pipeline with a memory store and an explicit relevance filter — which is exactly the thing we needed and had failed to design on our own.",
      },
      { type: "h", text: "How it maps in the system" },
      {
        type: "p",
        text: "Manas is the intake layer. Speech recognition across forty-odd languages, face detection, object tracking, gesture input. It registers everything and resolves nothing. It is permitted to be uncertain and to hold competing readings simultaneously.",
      },
      {
        type: "p",
        text: "Chitta is persistent memory. Faces she has encountered, what was discussed, what someone asked for last time. Not a cache — a store of impressions that shapes how later input is interpreted.",
      },
      {
        type: "p",
        text: "Ahankara is the piece that does the most work and gets the least attention. It answers one question about every incoming stimulus: is this addressed to me? Someone saying 'where is the library' two metres away, facing elsewhere, mid-conversation with a friend, is not talking to Anushka. A flat architecture has to be told that with a rule. A system with an explicit self-reference layer treats it as the normal operation of a dedicated faculty.",
      },
      {
        type: "quote",
        text: "Most of being a good receptionist is correctly determining what is not your business.",
      },
      {
        type: "p",
        text: "Buddhi is the decision layer, and it sits on top of BOSS — the Bot Operations Scheduling System we wrote to run her. It takes what Manas registered, what Chitta knows, and what Ahankara flagged as self-relevant, and commits to one action. It is the only layer permitted to commit. That restriction is the whole point.",
      },
      { type: "h", text: "Why not just build it directly" },
      {
        type: "p",
        text: "A fair objection: all of this could have been designed from first principles, with ordinary names, as an attention pipeline. The four Sanskrit terms add nothing a well-drawn block diagram would not.",
      },
      {
        type: "p",
        text: "Possibly. But we did not design it from first principles. We tried, and what we produced was a flat loop with rules bolted on, because that is what you naturally produce when you are deep in the problem. The model gave us a decomposition that was already worked out, already load-bearing, and — this is the part I did not expect — already stress-tested against exactly our failure mode. The distinction between registering and committing is not an obvious design insight. It is the first thing this model insists on.",
      },
      {
        type: "p",
        text: "Borrowing a structure that has been refined for three thousand years is not mysticism. It is the same instinct as reaching for a known algorithm instead of inventing one at three in the morning.",
      },
      { type: "h", text: "What I am not claiming" },
      {
        type: "p",
        text: "Anushka is not conscious. She has no inner life, the architecture is an engineering borrowing and not a metaphysical assertion, and I would be embarrassed to suggest otherwise. Naming a scheduler Buddhi does not give it discriminative wisdom.",
      },
      {
        type: "p",
        text: "What I will claim is narrower and I think more interesting: the tradition was describing the architecture of attention with real precision, and that description survives translation into software. We did not use it because it was Indian and the press would like it. We used it because after months of failing to design the thing ourselves, it was the best decomposition we found.",
      },
    ],
  },
];

export { thoughts };
