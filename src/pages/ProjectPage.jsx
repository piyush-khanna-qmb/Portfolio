import React from "react";
import { useParams, Link, Navigate } from "react-router-dom";

import { projectMedia } from "../constants/projectMedia";
import ArrowUpRight from "../components/ArrowUpRight";
import CapabilityGrid from "../components/CapabilityGrid";
import PromptCards from "../components/PromptCards";
import MediaCarousel from "../components/MediaCarousel";
import PageShell from "./PageShell";

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
};

const ProjectPage = () => {
  const { slug } = useParams();
  const project = projectPages[slug];
  const media = projectMedia[slug];

  if (!project) return <Navigate to='/' replace />;

  return (
    <PageShell
      eyebrow={project.eyebrow}
      title={project.title}
      intro={project.intro}
    >
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


      {project.sections.map((section) => (
        <section key={section.heading} className='mt-12'>
          <h2 className='max-w-3xl text-white font-bold text-[22px] sm:text-[25px] leading-[33px]'>
            {section.heading}
          </h2>
          <p className='max-w-3xl mt-4 text-secondary text-[17px] leading-[32px]'>
            {section.body}
          </p>
          {/* Grids and prompt rows run the full page width. Inside the
              768px prose column three cards left ~120px each for text,
              which wrapped the sentences to one word per line. */}
          {section.grid && <CapabilityGrid groups={section.grid} />}
          {section.prompts && <PromptCards groups={section.prompts} />}
        </section>
      ))}

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
              {project.links.map((link) => (
                <a
                  key={link.url}
                  href={link.url}
                  target='_blank'
                  rel='noopener noreferrer'
                  className='group text-secondary hover:text-[#915EFF] text-[15px] leading-[26px] transition-colors duration-300'
                >
                  <span className='inline-flex items-center gap-1.5'>
                    {link.label}
                    <ArrowUpRight className='w-3.5 h-3.5 shrink-0 text-[#915EFF]' />
                  </span>
                </a>
              ))}
            </div>
          </section>
        )}

      </div>

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
    </PageShell>
  );
};

export default ProjectPage;
