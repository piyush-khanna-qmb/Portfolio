import {
  galleryAnushkaRss,
  galleryAnushkaYogi,
  piyushWithAnushka,
  dtuChiefSpeaker,
  portfolioPhoto,
  profilePhoto,
  certOxyana,
  certIitkSecurity,
  certGuvi,
  certAlgoToolbox,
  certIntroAi,
  certFlipkart,
  certTata,
  certScaler,
  certNasa,
  certNetflix,
  certSwiggy,
} from "../assets";

/* ------------------------------------------------------------------ *
 * PRESS
 * Ordered deliberately: the Tycoon World / Medium pieces lead because
 * they are the ones that foreground "Young Visionary Piyush Khanna"
 * rather than only the robot.
 * `date` is only set where it is actually derivable from the source
 * URL. Nothing here is invented.
 * ------------------------------------------------------------------ */
const pressReleases = [


  {
    outlet: "Tycoon World",
    title:
      "Young Visionary Piyush Khanna Unveils Anushka, India's First Vedic-Principled Humanoid Robot",
    blurb:
      "A profile piece on the thinking behind Anushka, and why a humanoid built in India should model the mind the way Indian philosophy already does.",
    url: "https://tycoonworld.in/young-visionary-piyush-khanna-unveils-anushka-indias-first-vedic-principled-humanoid-robot-redefining-the-future-of-human-robot-interaction/",
    featured: true,
  },
  {
    outlet: "Interesting Engineering",
    title: "Anushka: India's humanoid robot",
    blurb:
      "An engineering-press breakdown of Anushka's build, actuation and the constraints the team designed around.",
    url: "https://interestingengineering.com/innovation/anushka-indias-humanoid-robot",
    featured: true,
  },
  {
    outlet: "Dainik Bhaskar",
    title: "Anushka, the robot whose heart beats",
    url: "https://www.bhaskar.com/local/uttar-pradesh/ghaziabad/news/anushkaa-robot-whose-heart-beats-132765604.html",
    language: "Hindi",
    featured: true,
  },
  {
    outlet: "Amar Ujala",
    title:
      "Anushka, a humanoid robot built from waste material by Piyush Khanna's team",
    url: "https://www.amarujala.com/delhi-ncr/ghaziabad/kite-collage-students-create-their-first-humanoid-robot-anushka-from-waste-material-2024-03-23",
    date: "Mar 2024",
    language: "Hindi",
    featured: true,
  },
  {
    outlet: "ShiftDelete",
    title: "Humanoid robot with a beating heart that knows 61 languages",
    blurb:
      "Turkish tech press on the two details that travelled furthest: the simulated heartbeat and the language range.",
    url: "https://en.shiftdelete.net/humanoid-robot-with-a-beating-heart-it-knows-61-languages/",
    language: "Turkey",
    featured: true,
  },
  {
    outlet: "IT Business",
    title: "Dobogó szívű robot Indiából",
    blurb:
      "Hungarian coverage of a humanoid built in India on a fraction of the usual budget.",
    url: "https://itbusiness.hu/technology/gadget/dobogo-szivu-robot-indiabol/",
    language: "Hungary",
    featured: true,
  },
  {
    outlet: "The Indian Express",
    title: "Meeting Anushka, a low-budget humanoid robot",
    blurb:
      "National coverage of how a student team built a working humanoid on frugal, largely salvaged hardware.",
    url: "https://indianexpress.com/article/technology/tech-news-technology/meeting-anushka-humanoid-robot-low-budget-frugal-tech-9507520/",
  },
  {
    outlet: "Mint",
    title:
      "AI humanoid robots: Anushka, Sophia, Vyommitra and the state of Indian robotics",
    blurb:
      "Anushka placed alongside Sophia and Vyommitra in a survey of where humanoid robotics stands in India.",
    url: "https://www.livemint.com/technology/ai-humanoid-robots-anushka-sophia-vyommitra-robotics-vinayak-boston-dynamics-brain-computer-interface-11724904446613.html",
    date: "Aug 2024",
  },
  {
    outlet: "Supercar Blondie",
    title: "Students build humanoid robot with a beating heart",
    blurb:
      "International pickup of the detail that made Anushka travel furthest: a mechanically simulated heartbeat.",
    url: "https://supercarblondie.com/students-build-humanoid-robot-beating-heart/",
  },
  {
    outlet: "UNILAD Tech",
    title: "Students build robot with beating heart",
    url: "https://www.uniladtech.com/news/ai/students-build-robot-with-beating-heart-402592-20240819",
    date: "Aug 2024",
  },
  {
    outlet: "News18 Hindi",
    title:
      "Ghaziabad's humanoid robot Anushka, a robot that is expert in all tasks",
    url: "https://hindi.news18.com/news/uttar-pradesh/ghaziabad-human-robot-anushka-prepared-in-ghaziabad-this-robot-is-expert-in-all-tasks-8208533.html",
    language: "Hindi",
  },
  {
    outlet: "Tricity Today",
    title: "A humanoid robot with a beating heart, invented in Ghaziabad",
    url: "https://tricitytoday.com/ghaziabad/kite-college-students-invented-heart-beating-robot-in-ghaziabad-53475.html",
  },
  {
    outlet: "Channel iam",
    title: "Anushka, the humanoid robot from Ghaziabad",
    url: "https://en.channeliam.com/2024/08/12/anushka-humanoid-robot-kiet-ghaziabad/",
    date: "Aug 2024",
  },
  {
    outlet: "The Northlines",
    title: "Meeting the amazing Anushka robot, built on a shoestring budget",
    url: "https://thenorthlines.com/meeting-the-amazing-anushka-robot-built-on-a-shoestring-budget/",
  },
  {
    outlet: "MyNation",
    title: "Low-cost humanoid robot Anushka engineered by UP college students",
    url: "https://www.mynation.com/india-untold/low-cost-humanoid-robot-anushka-engineered-by-up-college-students-iwh-si3chl",
  },
  {
    outlet: "Asianet News",
    title:
      "Watch: Anushka, the ₹2 lakh humanoid robot built by students in India",
    url: "https://www.asianetnews.com/technology/watch-anushka-2-lakh-costs-humanoid-robot-built-by-students-in-india-si3933",
  },
  {
    outlet: "Medium",
    title:
      "Young Visionary Piyush Khanna Unveils Anushka, India's First Vedic-Principled Humanoid Robot",
    blurb:
      "The long-form version of the Tycoon World profile, covering the Vedic architecture behind Anushka's decision-making.",
    url: "https://medium.com/@tycoonworld.in/young-visionary-piyush-khanna-unveils-anushka-indias-first-vedic-principled-humanoid-robot-b82cbfa4595a",
  },
  {
    outlet: "Business Tech Africa",
    title: "Anushka, the humanoid robot",
    url: "https://www.businesstechafrica.co.za/technology/2024/08/13/anushka-the-humanoid-robot/",
    date: "Aug 2024",
  },
  {
    outlet: "PC-Tablet",
    title:
      "Encountering Anushka, a low-budget humanoid robot with a unique story",
    url: "https://www.pc-tablet.co.in/encountering-anushka-a-low-budget-humanoid-robot-with-a-unique-story/37605/",
  },
  {
    outlet: "NT News",
    title: "Creation of an amazing humanoid robot out of waste",
    url: "https://www.ntnews.com/national/creation-of-an-amazing-humanoid-robot-out-of-waste-1695095",
    language: "Telugu",
  },
  {
    outlet: "Zollege",
    title: "Anushka, a first-of-its-kind humanoid robot, officially unveiled",
    url: "https://zollege.in/news/c-173359-kiet-officially-unveils-its-first-ever-humanoid-robot-anushka",
  },
  {
    outlet: "India Forums",
    title: "Meet Anushka, the robot",
    url: "https://www.indiaforums.com/forum/bollywood/5359567/meet-anushka-the-robot",
  },
  {
    outlet: "Shah Times",
    title: "Anushka: a first humanoid robot unveiled in Ghaziabad",
    url: "https://www.shahtimesnews.com/anushka-kite-college-unveils-its-first-humanoid-robot/",
  },
  {
    outlet: "KnowTechTics",
    title: "Anushka, a budget-friendly humanoid robot",
    url: "https://knowtechtics.com/anushka-a-budget-friendly-humanoid-robot/",
  },
  {
    outlet: "Unlimited ASR",
    title: "Anushka, the humanoid robot built from recycled parts",
    url: "https://unlimitedasr.com/robotics/anushka-the-humanoid-robot-built-from-recycled-parts/",
  },
  {
    outlet: "RobotShop Community",
    title:
      "India's AI humanoid robot with a beating heart, born from a scrap yard",
    url: "https://community.robotshop.com/forum/t/india-s-ai-humanoid-robot-with-beating-heart-born-from-scrap-yard-https-interestingengineering-com-innovation-anushka-indias-humanoid-robot/108344",
  },
];

/* Broadcast and social pickups: short-form video coverage. */
const pressSocial = [
  {
    platform: "X",
    handle: "@ExpressTechie",
    url: "https://x.com/ExpressTechie/status/1823189432767336818",
  },
  {
    platform: "X",
    handle: "@ExpComputer",
    url: "https://x.com/ExpComputer/status/1822822858709442666",
  },
  {
    platform: "YouTube",
    handle: "Anushka, full feature",
    url: "https://www.youtube.com/watch?v=p8jCVTSa3Ww",
  },
  {
    platform: "YouTube",
    handle: "Anushka, demonstration",
    url: "https://www.youtube.com/watch?v=yc4h9O5DSXg",
  },
  {
    platform: "Instagram",
    handle: "@theroboticsindia",
    url: "https://www.instagram.com/theroboticsindia/p/C-kxLYkNN_U/",
  },
  {
    platform: "Instagram",
    handle: "@channeliamdotcom",
    url: "https://www.instagram.com/channeliamdotcom/p/C-j5GSFATV4/",
  },
  {
    platform: "Facebook",
    handle: "Edureka",
    url: "https://www.facebook.com/edurekaIN/photos/anushka-the-humanoid-robot-built-by-a-team-of-students-and-professors-at-the-kri/935019251997242/",
  },
  {
    platform: "LinkedIn",
    handle: "Dr. Omkar Rai",
    url: "https://www.linkedin.com/posts/dromkarrai_meeting-anushka-a-low-budget-humanoid-robot-activity-7228609952750133248-314O/",
  },
  {
    platform: "Threads",
    handle: "@theinfomance",
    url: "https://www.threads.net/@theinfomance/post/C-vHR_ATuNe?hl=en",
  },
];

/* ------------------------------------------------------------------ *
 * RESEARCH & PATENTS
 * Deliberately no venue/DOI claimed for the paper, because none is stated in
 * the manuscript. The patent's filing address is intentionally omitted.
 * ------------------------------------------------------------------ */
const publications = [
  {
    kind: "Patent",
    entryDate: "19 Aug 2026",
    entryRef: "App. No. 202611100293",
    entryStatus: "Filed \u00b7 Patent application",
    title:
      "A Modular IoT Ecosystem Comprising Independent Sensor-Relay Extension Modules",
    subtitle:
      "Controller General of Patents, Designs & Trade Marks",
    body: "The architecture behind the Emperia automation ecosystem: a hub that stays deliberately simple, and sensor/relay modules that can be added independently without the hub needing to know in advance what they are. The claim is the extension model itself: modules that extend what the system can do without extending how complicated it is.",
  },
  {
    kind: "Research Paper",
    entryDate: "IEEE format",
    entryStatus: "Written up \u00b7 Manuscript",
    title:
      "Elevating Customer Engagement: The Role of Humanoid Robots as Receptionists",
    subtitle:
      "Piyush Khanna, Neha Shukla",
    body: "A study of what actually changes when a humanoid robot takes a receptionist's seat in an educational institution. The paper looks at multithreaded interaction handling, semantic analysis of visitor intent, and what the authors call empathetic technology, meaning the gap between a system that answers correctly and one that a person feels attended to by.",
    keywords: [
      "Humanoid Robots",
      "Customer Engagement",
      "Multithreading",
      "Human-Robot Interaction",
      "Semantic Analysis",
      "Empathetic Technology",
    ],
  },
];

/* ------------------------------------------------------------------ *
 * CERTIFICATES
 * Every blurb below is grounded in what the certificate itself states.
 * ------------------------------------------------------------------ */
const certificates = [

  {
    image: certOxyana,
    title: "Oxyana: Oxygen Analyzer",
    issuer: "MBS India",
    date: "Aug – Sep 2022",
    blurb:
      "Awarded for my work as Research Intern on the Oxyana oxygen analyzer, a ₹70,000 consultancy project with MBS India. This is the one I keep closest, because it was the first time something I worked on was destined for a hospital rather than a demo table, and biomedical hardware forgives nothing.",
  },
  {
    image: certGuvi,
    title: "Guinness World Record: Participant",
    issuer: "GUVI, in association with AICTE & NEAT",
    date: "24–25 April 2021",
    blurb:
      "Part of the Guinness World Record event for the most users taking an online computer programming lesson in 24 hours. Not a skill award, but a reminder that scale is its own kind of engineering problem, and I was one data point inside a very large one.",
  },
  {
    image: certIitkSecurity,
    title: "Computer System Security",
    issuer: "E & ICT Academy, IIT Kanpur (MeitY initiative)",
    date: "Aug 2021 – Mar 2022",
    blurb:
      "An eight-month certification course at IIT Kanpur's E&ICT Academy. It changed how I build: once you have seen how systems are actually broken into, you stop treating security as a layer added at the end.",
  },
  {
    image: certAlgoToolbox,
    title: "Algorithmic Toolbox",
    issuer: "UC San Diego & HSE University (Coursera)",
    date: "18 Jan 2022",
    blurb:
      "The fundamentals course I wish I had taken earlier. Greedy, divide-and-conquer, dynamic programming: the vocabulary that lets you recognise a problem you have already solved in a different costume.",
  },
  {
    image: certIntroAi,
    title: "Introduction to Artificial Intelligence",
    issuer: "IBM (Coursera)",
    date: "16 Jun 2021",
    blurb:
      "Taken in my second year, well before Anushka existed. Worth listing because it is where the idea of a machine that recognises a face stopped being science fiction to me and started being an API I could call.",
  },
  {
    image: certFlipkart,
    title: "Flipkart GRiD 5.0: Robotics Challenge",
    issuer: "Flipkart",
    date: "Level 1 qualifier",
    blurb:
      "Cleared Level 1 of Flipkart's national robotics challenge. A good calibration exercise, because competing against teams outside your own college tells you quickly which of your strengths are real.",
  },
  {
    image: certTata,
    title: "Tata Imagination Challenge 2022",
    issuer: "Tata Group",
    date: "Round 1",
    blurb:
      "Round 1 of the Tata Imagination Challenge. Pitching to a brand assessment panel rather than an engineering one forced me to explain an idea without a single schematic, which I was bad at and needed to be.",
  },
  {
    image: certScaler,
    title: "Scaler CodeX 2.0",
    issuer: "Scaler & InterviewBit",
    date: "6 Feb 2022",
    blurb:
      "A national-level competitive coding contest. Timed problems under pressure are a very different muscle from building systems slowly and carefully, and it is worth keeping both.",
  },
  {
    image: certNasa,
    title: "How NASA Auto-Colourises Images with Deep Learning",
    issuer: "TechLearn",
    date: "26 Jun 2021",
    blurb:
      "A session on the deep learning pipeline behind colourising archival space imagery. Filed here because it was the first time I saw a neural network used to restore something rather than classify it.",
  },
  {
    image: certNetflix,
    title: "How the Netflix Recommendation System Works",
    issuer: "TechLearn",
    blurb:
      "A teardown of Netflix's recommendation architecture. The lasting takeaway was not the algorithm but the product lesson: the hardest part of a recommender is deciding what you are optimising for.",
  },
  {
    image: certSwiggy,
    title: "How the Swiggy Chatbot Works",
    issuer: "TechLearn",
    date: "29 May 2021",
    blurb:
      "An early session on conversational systems in production. Three years later I was building dialogue handling for a humanoid receptionist, and a surprising amount of it rhymed.",
  },
];

/* ------------------------------------------------------------------ *
 * GALLERY
 * ------------------------------------------------------------------ */
const galleryPhotos = [
  {
    image: piyushWithAnushka,
    title: "Anushka with its creator",
    caption:
      "The Mechatronics lab, standing next to the thing that took a year and a half of my life. She is in a saree because we wanted her to read as Indian before she read as a robot.",
  },
  {
    image: galleryAnushkaYogi,
    title: "Anushka meets the Chief Minister",
    caption:
      "Anushka presented to Hon'ble Chief Minister Yogi Adityanath. Watching a machine you soldered together hold a room is a strange, excellent feeling.",
  },
  {
    image: galleryAnushkaRss,
    title: "Anushka Meets Dr. Atul Kothari",
    caption:
      "Presenting Anushka to Dr. Atul Kothari, chief secretary of SSUN, India. Demonstrations like this taught us more about her than any test we designed ourselves.",
  },
  {
    image: dtuChiefSpeaker,
    title: "Chief Speaker at DTU",
    caption:
      "Invited to Delhi Technological University as Chief Speaker on Mechatronics. First time I had been introduced as the person others came to hear rather than the student in the third row.",
  },
  {
    image: portfolioPhoto,
    title: "At the desk",
    caption:
      "Where most of the actual work happens. Considerably less photogenic than the robot, considerably more hours.",
  },
  {
    image: profilePhoto,
    title: "Off the clock",
    caption:
      "Somewhere in the Nilgiris, deliberately far from a terminal. The ideas that survive are usually the ones that followed me on a trip like this.",
  },
];

export {
  pressReleases,
  pressSocial,
  publications,
  certificates,
  galleryPhotos,
};
