import React from "react";
import { useParams, Link, Navigate } from "react-router-dom";

import { projectMedia } from "../constants/projectMedia";
import ArrowUpRight from "../components/ArrowUpRight";
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
    related: {
      label: "I wrote about the theological problem in more detail",
      to: "/thoughts/sunaina-live-durga-robot",
    },
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

  dadashree: {
    eyebrow: "Robotics · Human-robot interaction",
    title: "DadaShree",
    intro:
      "A humanoid named with a relational honorific instead of a personal name: Dada, elder brother, plus the honorific Shree. The naming is the interface.",
    facts: [
      { label: "Type", value: "Humanoid robot" },
      { label: "Focus", value: "Human-robot interaction" },
      { label: "Naming", value: "Relational honorific, 'respected elder brother'" },
    ],
    sections: [
      {
        heading: "The argument behind the name",
        body: "Western humanoids get names that imply either an abstraction or a peer: Sophia, Ameca, Atlas. That works where the default relationship between person and machine is transactional. In India the first thing established with a stranger is not their name but their relational position, and once that slot is assigned, everything else follows from it.",
      },
      {
        heading: "Why it matters in practice",
        body: "Name a robot something abstract and someone has to stand beside it explaining how to interact. Name it DadaShree and an Indian visitor already has the protocol, because they know how to talk to a Dada. The name does the onboarding that would otherwise cost you software.",
      },
    ],
    related: {
      label: "The full argument for the naming",
      to: "/thoughts/why-dadashree",
    },
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

        {project.sections.map((section) => (
          <section key={section.heading} className='mt-12'>
            <h2 className='text-white font-bold text-[22px] sm:text-[25px] leading-[33px]'>
              {section.heading}
            </h2>
            <p className='mt-4 text-secondary text-[17px] leading-[32px]'>
              {section.body}
            </p>
          </section>
        ))}

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
            This project got media highlights
          </h2>
          <p className='mt-3 text-secondary text-[16px] leading-[28px] max-w-3xl'>
            Coverage across television, news channels and social media through
            the festival. Pick any clip to play it.
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
