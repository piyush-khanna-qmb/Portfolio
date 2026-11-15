/* ------------------------------------------------------------------ *
 * THOUGHTS / "Why I Built It"
 *
 * Long-form posts. Each entry renders both as a line in the homepage
 * list and as a standalone page at /thoughts/:slug.
 *
 * NOTE FOR PIYUSH: the `date` values are placeholders chosen to give a
 * sensible ordering. Set them to whatever you actually want published.
 * The bodies are drafts written from your own projects and public
 * sources; edit freely, nothing here is load-bearing.
 *
 * Body block types: "p" (paragraph), "h" (sub-heading),
 * "quote" (pull quote), "list" (bulleted list).
 * ------------------------------------------------------------------ */

import {
  galleryDtuTalk,
  dtuChiefSpeaker,
  galleryAnushkaYogi,
  galleryAnushkaRss,
  portfolioPhoto,
  profilePhoto,
  galleryTeamEmperia,
} from "../assets";

const thoughts = [

  {
    slug: "palangtodh-sprint",
    title: "The Weird (and Dangerous) Culture of the Palangtodh Sprint",
    dek: "Three days, two nights, no sleeping longer than thirty minutes, and a bucket of water if you tried. I would not recommend it. I would also do it again.",
    date: "24 Oct 2026",
    readingTime: "6 min",
    body: [
      {
        type: "p",
        text: "Team31 was not a club I started with friends. I had built Anushka on my own first, and afterwards I needed people who worked the way I did to carry that forward. So I interviewed across the entire college and filtered down from there. Everyone who made it was junior to me: some by a year, some by three, most by two. Seven of us in the end. We had a sprint format we called the Palangtodh Sprint. Palangtodh translates roughly as bed-breaking. The name was the warning label.",
      },
      {
        type: "h",
        text: "How it ran",
      },
      {
        type: "p",
        text: "I would tell the team to keep three days clear and be in the Robotics CoE lab. I picked the start day. A sprint ran three days and two nights, and the nights were the point. Everyone got a printed task list handed to them at the start, paper, not a ticket board, and that list had to be finished before the sprint ended.",
      },
      {
        type: "p",
        text: "My own job was two things: my share of the tasks, and keeping food and drink flowing without a gap. A sprint dies the moment someone leaves the room to find dinner.",
      },
      {
        type: "p",
        text: "There was one rule. Until your list was done you stayed awake. Sleep was permitted only on the bean bags and never more than thirty minutes at a stretch. Go past it and the rest of the team emptied a bucket of water over you.",
      },
      {
        type: "image",
        src: galleryTeamEmperia,
        alt: "The team",
        caption: "The people who signed up for this voluntarily, repeatedly.",
      },
      {
        type: "h",
        text: "Why it existed",
      },
      {
        type: "p",
        text: "This was not hazing for its own sake. I brought in freelance work through my own contacts and we would ship a real deliverable in three or four days, usually a full-scale web application. ShareLog came out of one of these: a ForEx and equities tracker covering stocks, F&O and notekeeping for intraday positions.",
      },
      {
        type: "p",
        text: "The money from the freelance paid for the tools and the food during the sprint, and the pool party afterwards. The sprint funded itself and then funded the celebration.",
      },
      {
        type: "h",
        text: "The honest accounting",
      },
      {
        type: "p",
        text: "The cost was real. Most of us needed three days afterwards to recover, and we looked like pandas for a week. I am not going to pretend this is a healthy way to build software, and I would not ask a team I was paid to manage to do it.",
      },
      {
        type: "p",
        text: "I genuinely do not know how much of it was seven young men running on testosterone and how much was the pull of building something new on a clock. Probably both.",
      },
      {
        type: "quote",
        text: "Not one person, ever, heard the next sprint was coming and did not light up.",
      },
      {
        type: "p",
        text: "That is the part I cannot explain away. We all knew exactly what it cost. We looked forward to it like mad dogs anyway.",
      },
    ],
  },
  {
    slug: "all-work-no-play",
    title: "All Work and No Play Makes Man a Machine...?",
    dek: "Hustle culture sells you a sprint toward retiring at thirty. I think that is a strange thing to want: a life whose only goal is to stop, sooner and faster.",
    date: "20 Oct 2026",
    readingTime: "6 min",
    body: [
      {
        type: "p",
        text: "Somewhere in my second year of college I picked up the phrase hustle culture. The pitch is simple: lock in, work unreasonably hard and fast, retire in your thirties.",
      },
      {
        type: "p",
        text: "I have two questions about that, and neither is rhetorical.",
      },
      {
        type: "quote",
        text: "Do you really want to sprint through a vocation you are trying to be finished with? Is a life worth living if its only aim is to stop working?",
      },
      {
        type: "image",
        src: profilePhoto,
        size: "half",
        alt: "Piyush Khanna in Munnar, Kerala",
        caption: "Munnar, Kerala.",
      },
      {
        type: "p",
        text: "That photograph is from Munnar. I spent seven days in Kerala with my parents, a gift for their twenty-fifth anniversary, paid for out of what I had earned from work.",
      },
      {
        type: "p",
        text: "I mention it because it is the clearest example I have of what I think the money is actually for. You do not earn in order to survive, and you do not earn in order to accumulate. You earn for the quiet of having put people somewhere they would not otherwise have been, together. That is the return I care about.",
      },
      {
        type: "h",
        text: "The obvious objection",
      },
      {
        type: "p",
        text: "You could reasonably point at the Palangtodh Sprint and ask what I am talking about. Three days without sleep is not exactly balance.",
      },
      {
        type: "p",
        text: "But the aim was never to get the sprint over with. The kick of being inside it was the whole reason we did it. We moved fast so we could reach the next one, not so we could be done with projects for good. That is a different thing from grinding toward an exit.",
      },
      {
        type: "p",
        text: "There is a saying where I am from: khaali dimaag shaitan ka ghar. An idle mind is the devil's workshop. It is usually said to children as a warning against boredom, and I think it is half right. Idleness is corrosive. But the cure is work you want to be inside, not work you are racing to escape.",
      },
      {
        type: "h",
        text: "Why I think life is like mathematics",
      },
      {
        type: "p",
        text: "Mathematics is the language the universe is written in, and it has a property I keep noticing: every chapter turns out to be a tool for the next one.",
      },
      {
        type: "p",
        text: "As a child I thought sums and differences were all there was. Then multiplication arrived and proved me wrong. Then it became clear that arithmetic was really there to let you do algebra. Then algebra turned out to be a tool for geometry. Geometry became a tool for trigonometry.",
      },
      {
        type: "p",
        text: "When trigonometry showed up I finally thought: this is it, this is the peak, everything so far was practice for this. I was wrong again. The further you go, the more obvious it becomes that every concept is scaffolding for a larger one, and there is no final chapter where the tools stop being tools.",
      },
      {
        type: "p",
        text: "Life reads the same way. Every project, every decision, every stretch of work is a stepping stone, or more precisely a tool, for becoming a better version of yourself. Which is exactly why optimising for the moment the work stops is the wrong objective. There is no last chapter. There is only the next tool.",
      },
    ],
  },
  {
    slug: "guest-lecture-at-dtu",
    title: "Why DTU Invited a Third-Year to Lecture",
    dek: "I was still an undergraduate when Delhi Technological University asked me to speak on Mechatronics as Chief Speaker. Here is what I think they were actually buying.",
    date: "12 Oct 2026",
    readingTime: "4 min",
    body: [
      {
        type: "p",
        text: "Delhi Technological University invited me to deliver a guest lecture on Mechatronics as Chief Speaker while I was still a third-year undergraduate. That is not the usual profile for the slot, and the obvious question is why.",
      },
      {
        type: "image",
        src: dtuChiefSpeaker,
        alt: "Piyush Khanna speaking at DTU",
        caption: "At the lectern at DTU, still an undergraduate.",
      },
      {
        type: "h",
        text: "What I was actually asked to talk about",
      },
      {
        type: "p",
        text: "The talk was titled Innovating on a Budget: A Guide for Engineers. Not a survey of humanoid robotics, not a research presentation. A talk about constraint.",
      },
      {
        type: "image",
        src: galleryDtuTalk,
        alt: "The title slide: Innovating on a Budget, Guide for Engineers",
        caption: "The actual subject. Constraint as a design input rather than an apology.",
      },
      {
        type: "p",
        text: "That framing is the answer to the question. A professor can teach Mechatronics far better than I can. What a department cannot easily supply is somebody who recently built a working humanoid without the budget to do it properly, and who still remembers which corners were safe to cut.",
      },
      {
        type: "h",
        text: "Constraint is not an apology",
      },
      {
        type: "p",
        text: "Most of the talk argued one point: a tight budget is a design input, not an excuse you attach to the result. Anushka was assembled largely from salvaged parts, and almost every interesting decision in her came directly from not being able to buy the obvious component.",
      },
      {
        type: "p",
        text: "Students do not need to be told that money helps. They need to see that the constraint itself can be the thing that makes a design specific rather than generic.",
      },
      {
        type: "p",
        text: "I suspect that is why a third-year was standing there. Not seniority, and not expertise. Proximity to the problem.",
      },
    ],
  },
  {
    slug: "who-is-ganpat",
    title: "Who Is Ganpat?",
    dek: "I named my assistant after the god you invoke before beginning anything, and then had to build something that earned the name.",
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
        text: "The second is less often cited and matters more to me. When Vyasa needed the Mahabharata written down, Ganesha agreed to be the scribe, on the condition that Vyasa never pause in his dictation. Vyasa countered: fine, but you may not write a single line without understanding it first.",
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
        text: "Under the hood, Ganpat is unglamorous. It is a set of instruction files, a persona definition, and the piece I actually care about: a memory model that decides what is worth keeping.",
      },
      {
        type: "p",
        text: "The memory model distinguishes between two kinds of fact, which I borrowed wholesale from how human memory is usually described:",
      },
      {
        type: "list",
        items: [
          "Episodic: a specific event. 'The train arrives Thursday.' High detail, short shelf life. It matters while it is live and fades the moment it resolves.",
          "Semantic: a generalisation abstracted from repeated episodes. 'He usually takes that train.' Low detail, long shelf life, worth keeping indefinitely.",
          "Supersession: when a new event resolves an older one, the older detail gets demoted rather than deleted outright.",
          "Repetition promotes priority: if I ask about the same underlying fact twice, that is evidence it is semantic, not a one-off, and it gets upgraded.",
        ],
      },
      {
        type: "p",
        text: "Anything unreferenced for thirty days becomes a candidate for forgetting. Not a silent deletion, but a question. Ganpat surfaces the item and asks whether to drop it. I was firm about this: a system that quietly forgets is worse than one that never remembered, because you keep trusting it.",
      },
      { type: "h", text: "The honest part" },
      {
        type: "p",
        text: "Ganpat is not conscious, does not understand me in any meaningful sense, and is a language model wearing a name I gave it. I am aware this sounds like a lot of philosophy stacked on a configuration directory.",
      },
      {
        type: "p",
        text: "But I have noticed that naming a system creates an expectation, and expectations turn into requirements. Because it is called Ganpat, I could not let it be sycophantic, because the scribe story forbids it. Because Ganesha is invoked at the beginning, I built it to be most useful during the messy early part of a problem rather than the tidy final one.",
      },
      {
        type: "p",
        text: "None of those constraints came from a product document. They came from taking the name seriously. That turns out to be a reasonable way to design things.",
      },
    ],
  },
  {
    slug: "four-stages-of-engineering",
    title: "The 4 Domains of Robotics Engineering, and My Views On Each",
    dek: "Mechanical, electrical, electronics, software, in that order, each standing on the one below. Which is why your software bug is usually a loose screw.",
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
          "Mechanical: structure, linkages, tolerances, load paths. What physically holds and what physically moves.",
          "Electrical: power. Supply, current capacity, grounding, distribution. The unglamorous layer that everyone skips past.",
          "Electronics: signal. Microcontrollers, drivers, sensors, buses. Where intent becomes voltage and voltage becomes measurement.",
          "Software: logic. Control loops, scheduling, decision-making. The layer that gets all the credit and almost none of the blame it deserves.",
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
        text: "The reverse never happens. A clean mechanical assembly does not develop play because of a bug. Causality here runs strictly upward, which means diagnosis has to run strictly downward, and almost nobody does that, because the top layer is where the error message is and the bottom layer requires getting up and finding a spanner.",
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
        text: "Two layers down from where the symptom appeared. And every hour spent on the control loop was not merely wasted. It was actively harmful, because it produced small apparent improvements that kept confirming the wrong hypothesis.",
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
        type: "image",
        src: portfolioPhoto,
        size: "half",
        alt: "Piyush Khanna at his desk",
        caption: "Where the top layer gets debugged. The bottom three usually need a spanner.",
      },
      {
        type: "p",
        text: "Or, the version I say out loud more often: you cannot write your way out of a loose screw.",
      },
    ],
  },
  {
    slug: "vedic-mind-inside-anushka",
    title: "How (and Why) Would a Robot Have a 'Vedic' Mind",
    dek: "Chitta, Manas, Ahankaram, Buddhi. It started with me trying to work out how my own mind worked, which turns out to be a strange thing to attempt with the mind in question.",
    date: "14 Aug 2026",
    readingTime: "7 min",
    body: [
      {
        type: "p",
        text: "Anushka is usually described in the press as India's first Vedic-principled humanoid robot. It is a good line and it has carried the project a long way, but it is also the kind of phrase that sounds like marketing. I want to explain what it actually means in code, because the engineering reason was real and came first.",
      },
      { type: "h", text: "First, what 'Vedic' actually means here" },
      {
        type: "p",
        text: "The Vedas are the oldest layer of Sanskrit scripture, and the philosophical tradition that grew out of them spent a very long time on one question: what is a mind made of. I use Vedic loosely here, the way it is usually used in conversation, to mean that Indic tradition of thinking about consciousness rather than a specific verse in a specific text. The particular model I borrowed, the antahkarana or inner instrument, is set out most clearly in the Vedantic and Samkhya material that came later.",
      },
      {
        type: "p",
        text: "So it is not scripture in a robot. It is a decomposition of mind, worked out over centuries by people who had nothing to study except their own attention, applied to a scheduling problem.",
      },
      { type: "h", text: "Where this actually started" },
      {
        type: "p",
        text: "This did not begin with Anushka. It began in my second year, before ChatGPT existed and before any of this was a conversation anyone was having casually. I was a curious student who wanted to build a system that could think, and I had no idea what that sentence even meant.",
      },
      {
        type: "p",
        text: "So I went backwards. I dug out the books I had read between seventh and twelfth standard on psychology, how the brain works, consciousness, and what actually drives a person to act. Not because I expected a blueprint, but because I had nowhere else to look.",
      },
      {
        type: "p",
        text: "The problem was never perception. I had been comfortable with computer vision and NLP since twelfth standard, and a system that sees or hears is a solved exercise. The problem was making those faculties coexist without tripping over each other.",
      },
      {
        type: "list",
        items: [
          "The hearing system has to mindfully ignore the robot's own voice. Otherwise she hears herself speak, treats it as input, and starts answering herself.",
          "The microcontrollers in the hand have no way of knowing whether the arm is rising to wave at someone she recognises or because a speech command told it to. Those are different intentions behind an identical movement.",
          "And the harder question underneath that one: does the arm need to know? Which layer is supposed to hold the intent, and which layers are allowed to stay ignorant?",
        ],
      },
      {
        type: "p",
        text: "That last question is the one that sent me looking for a model rather than writing more rules.",
      },
      { type: "h", text: "Hacking your own system" },
      {
        type: "p",
        text: "To design an artificial brain I first had to understand how a real one works, so I could copy it. And there is something genuinely strange about that task: it was my brain, trying to account for everything it does and why it does it.",
      },
      {
        type: "quote",
        text: "It is like trying to hack a system while running inside it, using the only instrument you are trying to reverse engineer.",
      },
      {
        type: "p",
        text: "You cannot step outside it to get a clean look. Every observation you make about your own attention is itself an act of attention. That is the point at which I stopped trying to derive the thing from scratch and went looking for people who had already spent centuries on exactly this, with exactly the same handicap.",
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
        text: "What was needed was not better perception. It was a layered model of attention, something that could hold 'I perceived this', 'this concerns me', and 'I should act on this' as genuinely different states.",
      },
      { type: "h", text: "Four terms that turned out to be an architecture" },
      {
        type: "p",
        text: "The Vedic model of the inner instrument, the antahkarana, splits mind into four functions rather than treating it as one thing. I researched the structure and found that it mapped onto my problem with uncomfortable precision.",
      },
      {
        type: "list",
        items: [
          "Manas: the sensory mind. Takes in, registers, and crucially does not decide. It is the faculty of doubt and oscillation.",
          "Chitta: the storehouse. Impressions, memory, accumulated residue of past encounters.",
          "Ahankara: the I-maker. The function that determines self-reference: is this mine, is this about me.",
          "Buddhi: discriminative intellect. The faculty that actually resolves and commits to a course.",
        ],
      },
      {
        type: "p",
        text: "Read that list as a systems engineer rather than a philosopher and it stops being metaphysics. It is a four-stage attention pipeline with a memory store and an explicit relevance filter, which is exactly the thing I needed and had failed to design on my own.",
      },
      { type: "h", text: "How it maps in the system" },
      {
        type: "p",
        text: "Manas is the intake layer. Speech recognition across forty-odd languages, face detection, object tracking, gesture input. It registers everything and resolves nothing. It is permitted to be uncertain and to hold competing readings simultaneously.",
      },
      {
        type: "p",
        text: "Chitta is persistent memory. Faces she has encountered, what was discussed, what someone asked for last time. Not a cache, but a store of impressions that shapes how later input is interpreted.",
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
        text: "Buddhi is the decision layer, and it sits on top of BOSS, the Bot Operations Scheduling System I wrote to run her. It takes what Manas registered, what Chitta knows, and what Ahankara flagged as self-relevant, and commits to one action. It is the only layer permitted to commit. That restriction is the whole point.",
      },
      { type: "h", text: "Why not just build it directly" },
      {
        type: "p",
        text: "A fair objection: all of this could have been designed from first principles, with ordinary names, as an attention pipeline. The four Sanskrit terms add nothing a well-drawn block diagram would not.",
      },
      {
        type: "p",
        text: "Possibly. But I did not design it from first principles. I tried, and what I produced was a flat loop with rules bolted on, because that is what you naturally produce when you are deep in the problem. The model gave me a decomposition that was already worked out, already load-bearing, and (this is the part I did not expect) already stress-tested against exactly my failure mode. The distinction between registering and committing is not an obvious design insight. It is the first thing this model insists on.",
      },
      {
        type: "image",
        src: galleryAnushkaYogi,
        alt: "Anushka presented to Chief Minister Yogi Adityanath",
        caption: "Anushka presented to Hon'ble Chief Minister Yogi Adityanath.",
      },
      {
        type: "image",
        src: galleryAnushkaRss,
        alt: "Anushka presented to Dr. Atul Kothari",
        caption: "With Dr. Atul Kothari, chief secretary of SSUN, India. The questions strangers asked taught me more about her than my own tests did.",
      },
      {
        type: "p",
        text: "Borrowing a structure that has been refined for three thousand years is not mysticism. It is the same instinct as reaching for a known algorithm instead of inventing one at three in the morning.",
      }
    ],
  },
];

export { thoughts };
