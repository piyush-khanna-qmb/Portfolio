import React, { useLayoutEffect, useRef, useState } from "react";
import { useParams, Link, Navigate } from "react-router-dom";

import { projectMedia } from "../constants/projectMedia";
import ArrowUpRight from "../components/ArrowUpRight";
import CapabilityGrid from "../components/CapabilityGrid";
import PromptCards from "../components/PromptCards";
import MediaCarousel from "../components/MediaCarousel";
import SEO from "../components/SEO";
import Lightbox from "../components/Lightbox";
import PageShell from "./PageShell";

import anushkaCloseup from "../assets/anushka-timeline/anushka-closeup.jpg";
import anushkaFoundational from "../assets/anushka-timeline/anushka-foundational.jpg";
import anushkaWithCoreTeam from "../assets/anushka-timeline/anushka-with-core-team.jpg";
import anushkaFriendsAtWork from "../assets/anushka-timeline/friends-at-work.jpg";
import anushkaInitialCoding from "../assets/anushka-timeline/initial-coding-and-testing.jpg";
import anushkaPlanningWhiteboard from "../assets/anushka-timeline/robot-planning-whiteboard.jpg";
import anushkaTorsoBuild from "../assets/anushka-timeline/robots-torso.jpg";
import anushkaSleeplessNights from "../assets/anushka-timeline/working-sleepless-nights.jpg";

/**
 * Shell pages for the two robots that live on this site rather than on
 * an external domain. Piyush is writing the full project write-ups
 * himself. These establish the route, the chrome and the factual
 * skeleton so the project cards have somewhere real to land.
 */
const projectPages = {
  sunaina: {
    eyebrow: "Robotics · Durga Puja 2025",
    title: "Sunaina",
    intro:
      "A robotic Durga that stood as the presiding figure at Chakraberia Sarbojanin Durgotsab in Kolkata during Durga Puja 2025. Not an animatronic beside the idol, but the idol itself.",
    facts: [
      { label: "Deployment", value: "Chakraberia Sarbojanin Durgotsab, Kolkata" },
      { label: "Occasion", value: "Durga Puja 2025" },
      { label: "Recognition", value: "UltraTech Top 7 Pandals" },
      { label: "Broadcast", value: "ABP Ananda · Pratidin" },
    ],
    sections: [
      {
        heading: "What she was",
        body: "Sunaina was built to be looked at rather than operated. Articulated gaze, neck and hand movement, designed so that a person arriving for darshan would not need anything explained to them. For five days, lakhs of visitors stood in front of a machine and did what they had come to do.",
      },
      {
        heading: "Why it was harder than it looks",
        body: "The engineering was the easy half. The difficult part was theological, because an idol is conventionally inert until pran pratishtha invites the deity to be present in it. A form that already moves on its own complicates that separation in a way nobody on the build team was qualified to resolve.",
      },
      {
        heading: "Why a pandal is a difficult place to deploy",
        body: "A lab demo runs for ten minutes in front of people who want it to work. A pandal runs for five days in front of people who did not come to see a robot at all. There is no pausing to reset, no explaining a fault to the crowd, and no second attempt. Whatever she did at two in the afternoon on the busiest day was what everybody saw.",
      },
      {
        heading: "Built to be read, not operated",
        body: "Almost every design decision followed from one constraint: a visitor arriving for darshan should need nothing explained to them. No instructions, no attendant translating her behaviour, no interface. The movement had to be slow enough to read as presence rather than machinery, and the costume and jewellery had to carry more visual weight than the hardware underneath.",
      },
      {
        heading: "What the five days showed",
        body: "The response that stayed with me was not the press coverage or the award. It was older visitors, the group I had privately assumed would be most uneasy, folding their hands without hesitating. They were not evaluating a machine. They had come for darshan and that is what they did. The machinery was our problem, not theirs.",
      },
      {
        heading: "What is still open",
        body: "Whether she was the first live Durga robot in India is a claim I will not make flatly. Mechanised movement at pandals goes back decades, and robotic deities exist elsewhere. What I can say is narrower: neither we nor the organisers could find a prior instance of an articulated robotic Durga serving as the presiding idol rather than as a figure beside it. That is the distinction worth arguing about, and I would rather be accurate than impressive.",
      },
    ],
    links: [
      {
        label: "First look: Chakraberia Sarbojanin Durgotsab 2025",
        url: "https://www.facebook.com/explorewitharitra/videos/exclusive-first-look-of-chakraberia-sarbojanin-durgotsab-2k25kolkatas-first-pand/1499913928098170/",
      },
      {
        label: "Coverage reel",
        url: "https://www.instagram.com/reel/DPAm00JD_hu/?hl=en",
      },
      {
        label: "Video feature",
        url: "https://www.youtube.com/watch?v=9ApBbPmAdUE",
      },
    ],
  },

  omni: {
    eyebrow: "Mobile automation \u00b7 Android",
    title: "Emperia Omni",
    intro:
      "A natural-language automation harness for Android. You type what you want in plain English and it wires that sentence straight into the phone's real triggers and actions. No flowchart, no rule-builder, no recipe marketplace.",
    facts: [
      { label: "Platform", value: "Native Android (Kotlin). iOS coming soon." },
      { label: "Interface", value: "Plain English, one sentence" },
      { label: "Actions wired", value: "11, all working today" },
      { label: "Parsing", value: "On-device first, LLM only as fallback" },
    ],
    sections: [
      {
        heading: "The wall every automation app hits",
        body: "Tasker, IFTTT, Shortcuts, Samsung and Google Routines all share one problem: you have to learn their language before they will learn yours. Visual rule-builders, block diagrams, app-specific recipes. Every one of them is an interface you must be trained on before it becomes useful, which is why most people install one, build a single automation, and never open it again.",
      },
      {
        heading: "Trigger and action, nothing else",
        body: "Every automation that has ever existed is two primitives: something the operating system can detect, and something the operating system can do. Every tool in this category is just a different interface bolted onto that same pair. So instead of building another interface, enumerate the OS capability exhaustively and point a parser at that enumeration. The catalogue is the product. Not a chatbot wrapper, a harness.",
      },
      {
        heading: "Deterministic first, model second",
        body: "An on-device parser of roughly 1,100 lines resolves the overwhelming majority of real phrasing instantly, with no network call and no inference cost. A cloud model exists as a fallback for genuinely ambiguous prompts, but the product functions without it, and most usage never reaches it. That ordering matters commercially as much as technically: the unit economics work before a single subscriber exists.",
      },
      {
        heading: "Ask, do not guess",
        body: "Any ambiguity surfaces as an explicit choice rather than a silent assumption. Which contact, which app, which saved location. That is not politeness, it is the difference between a useful tool and a dangerous one once actions have real-world consequences. For anything irreversible the app stops short on purpose: calls open the dialer pre-filled rather than dialling, messages and emails fill the compose screen rather than sending.",
      },
      {
        heading: "What it actually does today",
        body: "Every pairing below is wired and working, not a mockup. Any trigger can drive any action, which is where the combinatorics come from.",
        grid: [
          {
            label: "Triggers",
            items: [
              { icon: "app", label: "App opened" },
              { icon: "place", label: "Location entered or left" },
              { icon: "time", label: "Time or schedule" },
              { icon: "bell", label: "Notification arrives" },
              { icon: "volume", label: "Volume threshold" },
              { icon: "bolt", label: "Fires immediately" },
            ],
          },
          {
            label: "Actions",
            items: [
              { icon: "alarm", label: "Set an alarm" },
              { icon: "timer", label: "Set a timer" },
              { icon: "phone", label: "Dial a call" },
              { icon: "sms", label: "Send an SMS" },
              { icon: "mail", label: "Send an email" },
              { icon: "bell", label: "Show a notification" },
              { icon: "app", label: "Open an app" },
              { icon: "link", label: "Open a URL" },
              { icon: "settings", label: "Open a settings page" },
              { icon: "torch", label: "Toggle the flashlight" },
              { icon: "volume", label: "Set exact volume" },
            ],
          },
        ],
      },
      {
        heading: "What it looks like to use",
        body: "No rule-builder and no setup screen. You write the sentence, it resolves what you meant, and asks when it genuinely cannot tell.",
        prompts: [
          {
            label: "Everyday",
            layout: "split",
            items: [
              {
                viz: "radar",
                kind: "Geofence + call",
                prompt: "If I'm at office and receive a call from a delivery partner, send a message to my Caretaker to collect it on my behalf.",
                note: "Resolved to one named contact, message pre-filled rather than sent.",
              },
              {
                viz: "pin",
                kind: "Location entered",
                prompt: "If I'm in Shopping mart, remind me to check Grocery list.",
                note: "Fires the moment you cross into the saved place.",
              },
              {
                viz: "apps",
                kind: "App opened",
                prompt: "When I open WhatsApp next time, remind me to revert to Prateek with BOM.",
                note: "Fires once, then retires itself.",
              },
            ],
          },
          {
            label: "Advanced capabilities",
            layout: "feature",
            items: [
              {
                viz: "sunrise",
                title: "The Perfect Morning Routine",
                prompt:
                  "Every morning, start waking me up usually at 7 AM with alarms spaced 10 minutes apart until I'm awake. If I start actively scrolling through my phone or turn on my bedroom ceiling lights, consider me awake and stop the remaining alarms. Then give me a concise morning briefing with the latest news, my commute to work, today's calendar and priorities, and add to my Google Tasks the to-do list based on my conversations and interactions with you yesterday. If traffic is unusually bad, suggest when I should leave.",
                steps: [
                  {
                    icon: "alarm",
                    fragment: "start waking me up usually at 7 AM with alarms spaced 10 minutes apart until I'm awake. If I start actively scrolling through my phone or turn on my bedroom ceiling lights, consider me awake",
                    result: "Schedules a repeating ladder of alarms from 07:00, ten minutes apart; either scrolling your phone or the bedroom lights coming on counts as awake and cancels whatever's left.",
                    api: "AlarmManager.setExactAndAllowWhileIdle + Intent.ACTION_USER_PRESENT + AccessibilityService",
                  },
                  {
                    icon: "news",
                    fragment: "a concise morning briefing with the latest news, my commute, today's calendar, and add to my Google Tasks the to-do list",
                    result: "Headlines, live commute time and today's events in one grouped notification, with yesterday's loose ends written to your task list.",
                    api: "Directions API + CalendarContract.Instances + Google Tasks API + NotificationCompat.InboxStyle",
                  },
                ],
              },
              {
                viz: "level",
                title: "Volume That Follows the Road",
                prompt:
                  "When I'm driving, map my song's volume to my speed. On traffic and red lights, set volume to 10%, and on highway max speed, volume can go up to 80%.",
                steps: [
                  {
                    icon: "speed",
                    fragment: "When I'm driving, map my song's volume to my speed",
                    result: "Picks up driving from sustained speed on its own, then maps current speed onto a volume curve rather than a single on-off rule.",
                    api: "ActivityRecognition IN_VEHICLE + FusedLocationProviderClient getSpeed()",
                  },
                  {
                    icon: "volume",
                    fragment: "On traffic and red lights, set volume to 10%, and on highway max speed, volume can go up to 80%",
                    result: "Near-stationary drops the stream to a tenth; the top of the curve is capped at 80% so highway speed never pins it at max.",
                    api: "AudioManager.setStreamVolume(STREAM_MUSIC), clamped against getStreamMaxVolume()",
                  },
                ],
              },
              {
                viz: "radar",
                title: "Arriving at Work, Already Caught Up",
                prompt:
                  "When I reach my office, open Keka and mark my attendance. Then check my work items for today and send me a concise summary on Slack, including my pending tasks, deadlines, meetings, and anything that needs my attention. If I haven't checked those messages, remind me before I get caught up in work.",
                steps: [
                  {
                    icon: "place",
                    fragment: "When I reach my office, open Keka and mark my attendance",
                    result: "A geofence on the saved office location fires once on entry and launches the attendance app straight to the action.",
                    api: "GeofencingClient.addGeofences + PendingIntent + getLaunchIntentForPackage deep link",
                  },
                  {
                    icon: "sms",
                    fragment: "send me a concise summary on Slack. If I haven't checked those messages, remind me",
                    result: "Today's tasks, deadlines and meetings as one digest where you already work, with a single nudge if it goes unread.",
                    api: "CalendarContract + Tasks API + Slack webhook + NotificationListenerService",
                  },
                ],
              },
              {
                viz: "night",
                title: "A Nighttime Routine That Takes No For an Answer",
                prompt:
                  "Every night after midnight, if I open Instagram, gently suggest that I read my novel instead and offer to open my reading app. If I choose to continue using Instagram, enable my blue-light filter, postpone my morning alarms by 30 minutes, and remind me that staying up late will affect tomorrow's sleep. Don't keep interrupting me after I've made my choice.",
                steps: [
                  {
                    icon: "time",
                    fragment: "Every night after midnight, if I open Instagram, gently suggest that I read my novel instead and offer to open my reading app",
                    result: "A time window plus that specific app coming to the foreground surfaces one actionable prompt, the reading app a single tap away.",
                    api: "AccessibilityService TYPE_WINDOW_STATE_CHANGED + time guard + NotificationCompat.Action",
                  },
                  {
                    icon: "shield",
                    fragment: "enable my blue-light filter, postpone my morning alarms by 30 minutes. Don't keep interrupting me",
                    result: "If you stay it limits the damage and rewrites tomorrow's alarms, then records the choice so the rule cannot fire again tonight.",
                    api: "Settings.ACTION_NIGHT_DISPLAY_SETTINGS + AlarmManager reschedule + per-night flag",
                  },
                ],
              },
            ],
          },
        ],
      },
    ],
    links: [],
  },

  dadashree: {
    eyebrow: "Robotics \u00b7 Parasdham, Junagadh",
    title: "DadaShree",
    intro:
      "A wisdom tree robot deployed at Parasdham, a Jain monastery in Junagadh, Gujarat. I lived on site for two months through July and August 2025 while building it.",
    facts: [
      { label: "Deployment", value: "Parasdham, Junagadh, Gujarat" },
      { label: "Setting", value: "Jain monastery" },
      { label: "On site", value: "July to August 2025" },
      { label: "Type", value: "Wisdom tree robot" },
    ],
    sections: [
      {
        heading: "The name",
        body: "Dada means grandfather. Shree is the honorific. Put together it points at a respected elder figure, and that is deliberate: it tells a visitor what posture to arrive in before anyone explains anything. You do not approach a grandfather the way you approach a kiosk. In a monastery, where people come with questions they have been carrying for a while, that framing does more work than any interface could.",
      },
      {
        heading: "Living on site",
        body: "I stayed at Parasdham for two months while the build came together. Working inside the place a machine is meant for is a different exercise from building it in a lab and shipping it. You see who actually walks up to it, what they ask, and how long they are willing to wait for an answer.",
      },
      {
        heading: "Junagadh in the monsoon",
        body: "It was a wholesome couple of months, and a good deal of that was the place itself. The weather in Junagadh was kind, and the rains arriving over those two months were the cherry on the cake. I also climbed Girnar, which is famous for roughly ten thousand steep steps and earns the reputation somewhere around step four thousand.",
      },
    ],
    links: [],
  },

  anushka: {
    eyebrow: "Robotics · India's Most Advanced Humanoid Robot",
    title: "Anushka",
    intro:
      "A humanoid robot that recognises faces, objects and gestures, and understands and responds to speech in multiple languages. Took four years to actually build, but the real story starts a lot earlier than that, in a 7th-grade bedroom, with a script that could only ever say what I'd already told it to.",
    facts: [
      { label: "Type", value: "Humanoid robot" },
      { label: "Built", value: "2nd to 4th year of college, unveiled 2024" },
      { label: "Capabilities", value: "Face, object & gesture recognition; multilingual speech" },
      { label: "Gestures", value: "64 hand gestures, 20+ eye expressions" },
    ],
    sections: [
      {
        heading: "A promise on the last day of school",
        body: "It all started with an introvert boy, his laptop, and the excitement to see it speak. I remember it was the end of 7th standard, a lazy Sunday morning in a retreating winter, when I stumbled onto SAPI, the speech engine built into my Windows 8 laptop, and heard it say back, “Good morning sir.”\nThat one line was enough to send me down a rabbit hole. I started writing Visual Basic scripts around that same engine, and what came out of it, an assistant I named Ganpat, could only answer prompts I'd already written for it myself, nothing soft about it at all. On the last day of 12th standard, I told my classmates I'd eventually build two full-scale robots: Anushka, and a second one called Vinayak.",
        image: anushkaCloseup,
        imageAlt: "Anushka, years after that first promise.",
        imageWidth: 340,
        imageHeight: 494,
        textWidth: 770,
        textHeight: 435,
      },
      {
        heading: "A box of loose wires",
        body: "The next real step came during the COVID lockdown, in my first year of college. My sister, who studied ECE, introduced me to Arduino and microcontrollers. I ordered a kit along with a few sensors and relay modules and used them to wire up my first home automation setup by the end of that year, controlled over an HC-05 Bluetooth module through an Android app I wrote in Java. The whole thing was flaky. The wires were crammed loosely into a box and it kept short-circuiting on me.",
        image: anushkaTorsoBuild,
        imageAlt: "The torso and arms mid-build, wiring still exposed on the bench.",
        imageWidth: 520,
        imageHeight: 364,
        textWidth: 600,
        textHeight: 314,
      },
      {
        heading: "Outgrowing Bluetooth",
        body: "Bluetooth's range was the obvious ceiling, so I did the obvious thing and complained about it to a professor at the start of second year. He pointed me at the ESP32, which had only just come out. But wanting to control the whole system from anywhere, not just from inside Bluetooth's modest little bubble, meant actually learning web development instead of improvising my way through it. By the end of second year I'd taught myself the full MERN stack, mostly out of necessity.",
      },
      {
        heading: "Ganpat learns to understand sentences",
        body: "By fall 2022 I'd rebuilt Ganpat with a machine learning layer underneath him, so he could actually parse natural language instead of just matching the exact phrases I'd hardcoded back in school. That one upgrade is what let me manage tasks, play music, set schedules, run the whole home automation setup from anywhere in the world over Wi-Fi. And this is the part people usually miss: it's the same thread that eventually became the decision-making model inside Anushka. Not a side project that happened to come later. The same one, just aimed at something much harder.",
      },
      {
        heading: "Toy cars wearing the word 'robot'",
        body: "College had only just reopened after the lockdown year, and I went straight to the robotics lab expecting more than I found there: toy cars, RC cars, line-followers, all filed under 'robots.' What did catch my attention was a set of actuator arms. I remember picturing them immediately: taken apart, rebuilt longer with heavier motors, mounted on a mannequin as the start of something with an actual presence. It worked. The first time it moved, the lab erupted.",
        image: anushkaInitialCoding,
        imageAlt: "Early days: the torso on the bench while the code behind it got written.",
        imageWidth: 500,
        imageHeight: 364,
        textWidth: 590,
        textHeight: 315,
      },
      {
        heading: "The three of us, most days",
        body: "Once that worked, the project needed more hands than mine. Harsh took on the mechanical structure, the base, and mounting the rebuilt arms onto the mannequin. Atul Sir, who ran the lab we set up Anushka's torso in, handled the electrical side.\nPhase 1 ran from around October 2022 through to a functioning prototype by January 2023. Phase 2 followed: a new base module, cut and built once university exams ended in March 2023.",
        image: anushkaFriendsAtWork,
        imageAlt: "Early motor and joystick testing, well before the wheeled base took its final shape.",
        imageWidth: 520,
        imageHeight: 386,
        textWidth: 570,
        textHeight: 384,
      },
      {
        heading: "The hardest summer",
        body: "Phase 3 started right after my birthday that year. Summer arrived and brought the heaviest stretch of the whole build with it. We all fell sick around the same time the seasons changed, and kept working anyway, eleven in the morning to seven the next. The last stretch was a three-day no-sleep push to get the whole assembly working together, and it did. That's when Anushka actually became a face, and when the Palangtodh Sprint, the sprint format my team kept running well after Anushka was done, got its name.",
        image: anushkaSleeplessNights,
        imageAlt: "One of many late nights spent fitting a module in.",
        imageWidth: 330,
        imageHeight: 444,
        textWidth: 730,
        textHeight: 377,
        related: {
          to: "/thoughts/palangtodh-sprint",
          label: "Read: The Weird (and Dangerous) Culture of the Palangtodh Sprint",
        },
      },
      {
        heading: "Showing her to the world",
        body: "Phase 3 ended with a demonstration at IIT Bombay on the first of August, 2023. Later, people I never expected a student project to meet came to see her in person: Atul Kothari, General Secretary of the RSS, and Uttar Pradesh's Chief Minister Yogi Adityanath, who formally inaugurated her, both visiting the lab she was built in.",
        image: anushkaWithCoreTeam,
        imageAlt: "The core team, with Anushka, at the Centre of Robotics and Mechatronics.",
        imageSide: "left",
        imageWidth: 560,
        imageHeight: 351,
        textWidth: 470,
        textHeight: 342,
      },
      {
        heading: "A heartbeat that wasn't supposed to matter",
        body: "She recognises faces, objects and gestures, and understands and responds to speech across multiple languages. One detail travelled further than I expected in the coverage: A Mechanically Simulated Heartbeat!\nIt was a small addition, but it was the thing that made people stop and look rather than just photograph her and move on. Underneath all of it, the jaw, the neck, the eyes, the hands each ran on their own microcontroller in their own little world, so I wrote an operating system from scratch to get them reporting to one master computer without stepping on each other: BOSS, Bot Operations Scheduling System, built on WSL.",
        textShiftY: -50,
        image: anushkaFoundational,
        imageAlt: "The torso, wheeled base, and first long arm, before there was a face to go with them.",
        imageWidth: 430,
        imageHeight: 544,
        textWidth: 580,
        textHeight: 371,
      },
      {
        heading: "A mind borrowed from the Vedas",
        body: "Her decision-making runs on the antahkarana, the four-part “inner instrument” set out in Vedantic and Samkhya philosophy, rather than a flat sense-process-decide-act loop. I started there because it was the clearest account I could find of how attention, memory and intent coexist without stepping on each other, and it happened to be written down in Sanskrit philosophy rather than a systems textbook.",
        image: anushkaPlanningWhiteboard,
        imageAlt: "Second-year whiteboard planning: component lists, wiring notes, and a rough sketch of the build.",
        imageWidth: 580,
        imageHeight: 385,
        textWidth: 440,
        textHeight: 367,
        related: {
          to: "/thoughts/vedic-mind-inside-anushka",
          label: "Read: How (and Why) Would a Robot Have a 'Vedic' Mind",
        },
      },
      {
        heading: "Sixty-four gestures, no depth sensor",
        body: "The feature list goes well past speech and a heartbeat, honestly. She's got sixty-four distinct hand gestures and more than twenty eye expressions, and her face recognition doesn't just clock who's standing in front of her, it changes how she greets them. The feature I'm most attached to, though, is 'Follow Me': she tracks and follows one specific person using computer vision alone, no depth-sensing camera involved, running a tracking algorithm I wrote myself instead of reaching for an off-the-shelf library. The same home automation and remote calling system I'd already built for Ganpat is wired into her too, so none of that earlier work got left behind just because the project moved from a phone app to an actual humanoid body.",
      },
    ],
    links: [
      {
        label: "Official site: anushkathehumanoid.com",
        url: "https://anushkathehumanoid.com",
      },
      {
        label: "Indian Express: Meeting Anushka, a low-budget humanoid robot",
        url: "https://indianexpress.com/article/technology/tech-news-technology/meeting-anushka-humanoid-robot-low-budget-frugal-tech-9507520/",
      },
      {
        label: "LiveMint: AI humanoid robots, Anushka, Sophia and Vyommitra",
        url: "https://www.livemint.com/technology/ai-humanoid-robots-anushka-sophia-vyommitra-robotics-vinayak-boston-dynamics-brain-computer-interface-11724904446613.html",
      },
      {
        label: "Interesting Engineering: Anushka, India's humanoid robot",
        url: "https://interestingengineering.com/innovation/anushka-indias-humanoid-robot",
      },
      {
        label: "Tycoon World: Young Visionary Piyush Khanna Unveils Anushka",
        url: "https://tycoonworld.in/young-visionary-piyush-khanna-unveils-anushka-indias-first-vedic-principled-humanoid-robot-redefining-the-future-of-human-robot-interaction/",
      },
    ],
    moreCoverageLink: "/press",
    ogImage: "https://piyushkhanna.space/piyush-khanna-creator-of-anushka-robot.jpg",
    ogImageAlt: "Piyush Khanna, creator of Anushka, India's humanoid robot",
    jsonLd: [
      {
        "@context": "https://schema.org",
        "@type": "Product",
        name: "Anushka",
        alternateName: "Anushka: The Humanoid",
        description:
          "Humanoid robot capable of face, object and gesture recognition and multilingual speech interaction, designed and built by Piyush Khanna over four years.",
        creator: {
          "@type": "Person",
          name: "Piyush Khanna",
          url: "https://piyushkhanna.space/",
        },
        url: "https://piyushkhanna.space/project/anushka",
        sameAs: ["https://anushkathehumanoid.com"],
        image: "https://piyushkhanna.space/piyush-khanna-creator-of-anushka-robot.jpg",
      },
      {
        "@context": "https://schema.org",
        "@type": "FAQPage",
        mainEntity: [
          {
            "@type": "Question",
            name: "Who created Anushka the robot?",
            acceptedAnswer: {
              "@type": "Answer",
              text: "Anushka was designed and built by Piyush Khanna, with a small team of collaborators, over four years starting in his second year of college. She is a humanoid robot capable of face, object and gesture recognition and multilingual speech interaction.",
            },
          },
        ],
      },
    ],
  },
};

const ProjectPage = () => {
  const { slug } = useParams();
  const project = projectPages[slug];
  const media = projectMedia[slug];
  const [activePhoto, setActivePhoto] = useState(null);

  const flowRef = useRef(null);
  const hasFreeFlow = !!project?.sections?.some(
    (s) => s.image && s.imageWidth
  );

  /*
   * Free-flowing two-column layout for the story sections (currently only
   * Anushka's sections set imageWidth, so every other page skips this).
   *
   * The reference layout treats text blocks and photos as independent
   * items in two columns, not as paired rows: the left column stacks its
   * items down its own cursor, the right column stacks down its own, so
   * a photo from one section climbs up beside the previous section's
   * text instead of waiting for it. Runs of consecutive image sections
   * are grouped into a relative container; on desktop this pass places
   * every item in the group with position:absolute, walking the two
   * column cursors in document order. A cross-column guard pushes an
   * item down whenever its box would land on an already placed item it
   * overlaps horizontally, so nothing can sit on top of anything else no
   * matter how text reflows. On mobile everything stays in normal
   * stacked flow and this pass only clears its own inline styles.
   */
  useLayoutEffect(() => {
    if (!hasFreeFlow) return undefined;

    const COL_GAP = 64;
    const CROSS_GAP = 40;
    const X_PAD = 16;

    const run = () => {
      const root = flowRef.current;
      if (!root) return;

      const desktop = window.matchMedia("(min-width: 640px)").matches;

      root.querySelectorAll("[data-masonry]").forEach((group) => {
        const items = [...group.querySelectorAll("[data-m-item]")];

        if (!desktop) {
          group.style.height = "";
          items.forEach((it) => {
            it.style.position = "";
            it.style.left = "";
            it.style.top = "";
          });
          return;
        }

        group.style.height = "";
        items.forEach((it) => {
          it.style.position = "absolute";
          it.style.left = "0px";
          it.style.top = "0px";
        });

        const groupWidth = group.offsetWidth;
        const cursors = { left: 0, right: 0 };
        const placed = [];
        let maxBottom = 0;

        items.forEach((it) => {
          const col = it.dataset.mCol;
          const w = it.offsetWidth;
          const h = it.offsetHeight;
          const x = col === "left" ? 0 : groupWidth - w;
          let y = cursors[col];

          let moved = true;
          while (moved) {
            moved = false;
            for (const p of placed) {
              const xHit = x < p.x + p.w + X_PAD && p.x < x + w + X_PAD;
              const yHit = y < p.y + p.h + CROSS_GAP && p.y < y + h;
              if (xHit && yHit) {
                y = p.y + p.h + CROSS_GAP;
                moved = true;
              }
            }
          }

          it.style.left = `${x}px`;
          it.style.top = `${y}px`;
          placed.push({ x, y, w, h });
          cursors[col] = y + h + COL_GAP;
          if (y + h > maxBottom) maxBottom = y + h;
        });

        group.style.height = `${maxBottom}px`;
      });
    };

    let frame = 0;
    const schedule = () => {
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(run);
    };

    schedule();
    window.addEventListener("resize", schedule);
    if (document.fonts && document.fonts.ready) {
      document.fonts.ready.then(schedule).catch(() => {});
    }

    return () => {
      cancelAnimationFrame(frame);
      window.removeEventListener("resize", schedule);
    };
  }, [slug, hasFreeFlow]);

  if (!project) return <Navigate to='/' replace />;

  return (
    <>
      <SEO
        title={project.title}
        description={project.intro}
        path={`/project/${slug}`}
        image={project.ogImage}
        imageAlt={project.ogImageAlt}
        jsonLd={project.jsonLd}
      />
      <PageShell
        eyebrow={project.eyebrow}
        title={project.title}
        intro={project.intro}
      >
      <div ref={flowRef}>
      <div className='max-w-3xl'>
        {/* Fact strip */}
        <dl className='grid grid-cols-1 sm:grid-cols-2 gap-4'>
          {project.facts.map((fact) => (
            <div key={fact.label} className='bg-tertiary rounded-xl px-5 py-4'>
              <dt className='text-secondary text-[11px] uppercase tracking-[0.12em]'>
                {fact.label}
              </dt>
              <dd className='mt-1 text-white text-[15px] font-medium'>
                {fact.value}
              </dd>
            </div>
          ))}
        </dl>

      </div>


      {(() => {
        let photoRow = 0;
        const resolved = project.sections.map((section) => {
          if (!(section.image && section.imageWidth)) {
            return { section, free: false };
          }
          const photoOnRight = section.imageSide
            ? section.imageSide === "right"
            : (photoRow += 1) % 2 === 1;
          return { section, free: true, photoOnRight };
        });

        const groups = [];
        resolved.forEach((entry) => {
          const last = groups[groups.length - 1];
          if (entry.free) {
            if (last && last.free) last.entries.push(entry);
            else groups.push({ free: true, entries: [entry] });
          } else {
            groups.push({ free: false, entry });
          }
        });

        return groups.map((group, gi) =>
          group.free ? (
            <div key={gi} data-masonry='true' className='relative mt-12'>
              {group.entries.map(({ section, photoOnRight }) => (
                <React.Fragment key={section.heading}>
                  <div
                    data-m-item='true'
                    data-m-col={photoOnRight ? "left" : "right"}
                    style={{
                      "--text-w": `${section.textWidth}px`,
                      "--text-mh": `${section.textHeight || 0}px`,
                    }}
                    className='w-full sm:w-[var(--text-w)] sm:min-h-[var(--text-mh)] mb-10 sm:mb-0'
                  >
                    <div
                      style={
                        section.textShiftY
                          ? { transform: `translateY(${section.textShiftY}px)` }
                          : undefined
                      }
                    >
                      <h2 className='text-white font-bold text-[22px] sm:text-[25px] leading-[33px]'>
                        {section.heading}
                      </h2>
                      <p className='mt-4 text-secondary text-[17px] leading-[32px]'>
                        {section.body.split("\n").map((line, i) => (
                          <React.Fragment key={i}>
                            {i > 0 && <br />}
                            {line}
                          </React.Fragment>
                        ))}
                      </p>
                      {section.related && (
                        <Link
                          to={section.related.to}
                          className='group mt-6 inline-flex items-center gap-3 max-w-[360px] bg-tertiary rounded-xl px-5 py-4 border border-transparent hover:border-[#915EFF]/40 transition-colors duration-300'
                        >
                          <span className='text-white text-[15px] font-medium group-hover:text-[#915EFF] transition-colors'>
                            {section.related.label}
                          </span>
                          <ArrowUpRight className='w-4 h-4 text-[#915EFF] shrink-0 ml-auto transition-transform group-hover:translate-x-0.5 group-hover:-translate-y-0.5' />
                        </Link>
                      )}
                    </div>
                  </div>
                  <button
                    type='button'
                    data-m-item='true'
                    data-m-col={photoOnRight ? "right" : "left"}
                    onClick={() =>
                      setActivePhoto({ image: section.image, caption: section.imageAlt })
                    }
                    aria-label='View photo'
                    style={{
                      "--photo-w": `${section.imageWidth}px`,
                      height: `${section.imageHeight}px`,
                    }}
                    className='group block w-full sm:w-[var(--photo-w)] mb-10 sm:mb-0 rounded-xl overflow-hidden border border-[#915EFF]/20 focus:outline-none focus-visible:ring-2 focus-visible:ring-[#915EFF]'
                  >
                    <img
                      src={section.image}
                      alt={section.imageAlt}
                      loading='lazy'
                      className='w-full h-full object-cover group-hover:scale-[1.02] transition-transform duration-300'
                    />
                  </button>
                </React.Fragment>
              ))}
            </div>
          ) : (
            <section key={group.entry.section.heading} className='mt-12'>
              <h2 className='max-w-3xl text-white font-bold text-[22px] sm:text-[25px] leading-[33px]'>
                {group.entry.section.heading}
              </h2>
              <p className='max-w-3xl mt-4 text-secondary text-[17px] leading-[32px]'>
                {group.entry.section.body}
              </p>
              {/* Grids and prompt rows run the full page width. Inside the
                  768px prose column three cards left ~120px each for text,
                  which wrapped the sentences to one word per line. */}
              {group.entry.section.grid && (
                <CapabilityGrid groups={group.entry.section.grid} />
              )}
              {group.entry.section.prompts && (
                <PromptCards groups={group.entry.section.prompts} />
              )}
              {group.entry.section.related && (
                <Link
                  to={group.entry.section.related.to}
                  className='group mt-6 max-w-3xl flex items-center gap-3 bg-tertiary rounded-xl px-5 py-4 border border-transparent hover:border-[#915EFF]/40 transition-colors duration-300'
                >
                  <span className='text-white text-[15px] font-medium group-hover:text-[#915EFF] transition-colors'>
                    {group.entry.section.related.label}
                  </span>
                  <ArrowUpRight className='w-4 h-4 text-[#915EFF] shrink-0 ml-auto transition-transform group-hover:translate-x-0.5 group-hover:-translate-y-0.5' />
                </Link>
              )}
            </section>
          )
        );
      })()}

      {project.photos && project.photos.length > 0 && (
        <section className='mt-16'>
          <h2 className='text-white font-bold text-[22px] sm:text-[25px] leading-[33px]'>
            From the build
          </h2>
          <div className='mt-6 columns-2 sm:columns-3 gap-4'>
            {project.photos.map((photo) => (
              <button
                key={photo.image}
                type='button'
                onClick={() => setActivePhoto(photo)}
                aria-label='View photo'
                className='group block w-full mb-4 break-inside-avoid rounded-xl overflow-hidden border border-[#915EFF]/20 focus:outline-none focus-visible:ring-2 focus-visible:ring-[#915EFF]'
              >
                <img
                  src={photo.image}
                  alt={photo.caption}
                  loading='lazy'
                  className='w-full h-auto group-hover:scale-[1.02] transition-transform duration-300'
                />
              </button>
            ))}
          </div>
        </section>
      )}

      <div className='max-w-3xl'>
        {project.related && (
          <Link
            to={project.related.to}
            className='group mt-12 flex items-center gap-3 bg-tertiary rounded-xl px-5 py-4 border border-transparent hover:border-[#915EFF]/40 transition-colors duration-300'
          >
            <span className='text-white text-[15px] font-medium group-hover:text-[#915EFF] transition-colors'>
              {project.related.label}
            </span>
            <ArrowUpRight className='w-4 h-4 text-[#915EFF] shrink-0 ml-auto transition-transform group-hover:translate-x-0.5 group-hover:-translate-y-0.5' />
          </Link>
        )}

        {project.links.length > 0 && (
          <section className='mt-12'>
            <h2 className='text-white font-bold text-[20px]'>Coverage</h2>
            <div className='mt-4 flex flex-col gap-2'>
              {project.links.map((link) => {
                const sepIdx = link.label.indexOf(":");
                const title = sepIdx !== -1 ? link.label.slice(0, sepIdx) : null;
                const rest = sepIdx !== -1 ? link.label.slice(sepIdx + 1).trimStart() : link.label;

                return (
                  <a
                    key={link.url}
                    href={link.url}
                    target='_blank'
                    rel='noopener noreferrer'
                    className='group text-secondary hover:text-[#915EFF] text-[15px] leading-[26px] transition-colors duration-300'
                  >
                    <span className='inline-flex items-center gap-1.5'>
                      {title && (
                        <span className='text-white/80 font-semibold group-hover:text-[#915EFF] transition-colors duration-300'>
                          {title}:
                        </span>
                      )}
                      {rest}
                      <ArrowUpRight className='w-3.5 h-3.5 shrink-0 text-[#915EFF]' />
                    </span>
                  </a>
                );
              })}
            </div>

            {project.moreCoverageLink && (
              <Link
                to={project.moreCoverageLink}
                className='group mt-2 inline-flex items-center gap-1.5 text-white font-medium hover:text-[#915EFF] text-[15px] leading-[26px] transition-colors duration-300'
              >
                And Many More...
                <ArrowUpRight className='w-3.5 h-3.5 shrink-0 text-[#915EFF]' />
              </Link>
            )}
          </section>
        )}

      </div>

      <Lightbox
        item={
          activePhoto && {
            image: activePhoto.image,
            blurb: activePhoto.caption,
          }
        }
        onClose={() => setActivePhoto(null)}
        emphasizeCaption={slug === "anushka"}
      />

      {/* Media highlights sit outside the prose column so the carousel can
          use the full page width. */}
      {media && (
        <section className='mt-16'>
          <h2 className='text-white font-bold text-[22px] sm:text-[25px] leading-[33px]'>
            {media.heading}
          </h2>
          <p className='mt-3 text-secondary text-[16px] leading-[28px] max-w-3xl'>
            {media.blurb}
          </p>

          {media.mentions && media.mentions.length > 0 && (
            <div className='mt-5 flex flex-wrap gap-2.5'>
              {media.mentions.map((mention) => (
                <span
                  key={mention.label}
                  className='flex items-baseline gap-2 bg-tertiary rounded-lg px-3.5 py-2'
                >
                  <span className='font-mono text-[10px] tracking-[0.12em] uppercase text-secondary/60'>
                    {mention.note}
                  </span>
                  <span className='text-white text-[14px] font-medium'>
                    {mention.label}
                  </span>
                </span>
              ))}
            </div>
          )}

          <div className='mt-8'>
            <MediaCarousel videos={media.videos} />
          </div>
        </section>
      )}

      {/* Honest status note: this is a shell, by design, for now. */}
      <p className='max-w-3xl mt-16 text-secondary/60 text-[13px] leading-[22px] border-t border-white/10 pt-6'>
        A fuller write-up of this project is in progress.
      </p>
      </div>
      </PageShell>
    </>
  );
};

export default ProjectPage;
