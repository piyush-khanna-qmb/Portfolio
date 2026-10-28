import {
  mobile,
  backend,
  creator,
  web,
  javascript,
  typescript,
  html,
  css,
  reactjs,
  redux,
  tailwind,
  nodejs,
  mongodb,
  git,
  docker,
  flutter,
  tpp,
  wipro,
  auto,
  mbs,
  fableroom,
  manojava,
  minerra,
  threejs,
  android,
  ocv,
  unity,
  tf,
  ros,
  java,
  py,
  piyushWithAnushka,
  projSunaina,
  projDadashree,
  projOmniVideo,
  brain,
  opti,
  hodWala,
  mbsWala,
  tppWala,
  deanWala
} from "../assets";

export const navLinks = [
  {
    id: "work",
    title: "Work",
  },
  {
    id: "contact",
    title: "Contact",
  },
];

const services = [
  {
    title: "Full Stack Web Applications",
    icon: web,
  },
  {
    title: "Internet of Things",
    icon: mobile,
  },
  {
    title: "Robotics and Automation",
    icon: backend,
  },
  {
    title: "Augmented Reality",
    icon: creator,
  },
];

const technologies = [
  {
    name: "Java",
    icon: java,
  },
  {
    name: "Python",
    icon: py,
  },
  {
    name: "React JS",
    icon: reactjs,
  },
  {
    name: "Node JS",
    icon: nodejs,
  },
  {
    name: "MongoDB",
    icon: mongodb,
  },
  {
    name: "git",
    icon: git,
  },
  {
    name: "Tensorflow",
    icon: tf,
  },
  {
    name: "ROS",
    icon: ros,
  },
  {
    name: "Flutter",
    icon: flutter,
  },
  {
    name: "Android",
    icon: android,
  },
  {
    name: "Docker",
    icon: docker,
  },
  {
    name: "OpenCV",
    icon: ocv,
  },
  {
    name: "Unity",
    icon: unity,
  },
];

const experiences = [
  {
    title: "Research Intern",
    company_name: "MBS India",
    icon: mbs,
    iconBg: "#E6DEDD",
    date: "May 2021 - July 2021",
    points: [
      "Reinforced and enhanced the design of Oxyana - Oxygen Concentrator for Soldiers, a patented product of MBS India.",
      "Researched applying Machine Learning to filter noisy signals in heartbeat and pulse forms, and engineered a design for a smart stethoscope using the same technology.",
    ],
  },
  {
    title: "Backend Developer",
    company_name: "Manojava Software India",
    location: "Noida (Sec-63), India",
    icon: manojava,
    iconFill: true,
    iconBg: "#29abe2",
    date: "Jan 2024 - Apr 2025",
    points: [
      "Designed and built scalable RESTful APIs with Node.js and Express.js — documented in Swagger, end-to-end tested in Postman, and backed by a MongoDB layer tuned through Mongoose for production query performance.",
      "Acted as System Architect, translating the founders' concept into a structured, scalable technical roadmap and development plan.",
    ],
  },
  {
    title: "FullStack Developer",
    company_name: "Minerra Health",
    location: "Remote (US)",
    icon: minerra,
    iconBg: "#ffffff",
    date: "Apr 2025 - July 2026",
    points: [
      "Developed and maintained scalable backend services in Python (Django & DRF), implementing secure, modular and reusable RESTful APIs consumed across web and mobile clients.",
      "Implemented JWT-based authentication and role-based access control for HIPAA-compliant data handling, and deployed the services on AWS EC2 with automated GitHub Actions CI/CD pipelines.",
    ],
  },
  {
    title: "Forward Deployed Engineer",
    company_name: "Fableroom",
    location: "DLF Golf Course, Gurgaon",
    icon: fableroom,
    iconFill: true,
    iconBg: "#9c6a14",
    date: "July 2026 - Present",
    points: [
      "Integrating logistics solutions into the company's in-house tooling, wiring third-party delivery and fulfilment workflows into systems built and owned internally.",
      "Working across a Python stack on AWS, with the customer-facing frontend built on Alpine.js.",
    ],
  },
];

const testimonials = [
  // {
  //   testimonial:
  //     "Piyush is a very honest and humble boy with extraordinary skillset and diligent mindset. He has already brought many laurels to us and the KIET family and I wish him all the luck for his future endeavours.",
  //   name: "Dr. Ajay Kr. Srivastava",
  //   designation: "HOD",
  //   company: "KIET CS",
  //   image: hodWala,
  // },
  {
    testimonial:
      "Piyush is a very honest and humble boy with extraordinary skillset and diligent mindset. He has already brought many laurels to us and the KIET family and I wish him all the luck for his future endeavours.",
    name: "Dr. Shubham Shukla",
    designation: "Dean",
    company: "KIET R&D",
    image: deanWala,
  },
  {
    testimonial:
      "We liked the work of Mr. Piyush very much. He was very cooperative during the entire process of site design and implementation and gave us creative ideas for the [User Interface] as well.",
    name: "Mr. Rasik Tiwari",
    designation: "CEO",
    company: "Teerth Purohit Prayagraj",
    image: tppWala,
  },
  {
    testimonial:
      "...We appreciate Mr. Piyush Khanna for his remarkable contribution for Oxyana: Oxygen Analyzer for Soldiers ©️. He is a dutiful person with a powerful skillset.",
    name: "Dr. Sundeep Rohilla",
    designation: "CEO",
    company: "MBS India",
    image: mbsWala,
  },

];

const projects = [

  {
    name: "Emperia Omni",
    description:
      "Part of the Emperia Automation Ecosystem — the IoT/home-automation platform built at Emperia Smart Solutions. Lives on the Emperia site alongside UniHub rather than here.",
    tags: [
      { name: "IoT", color: "blue-text-gradient" },
      { name: "Automation", color: "green-text-gradient" },
      { name: "Hardware", color: "pink-text-gradient" },
    ],
    image: null,
    video: projOmniVideo,
    source_code_link: null,
    linked_link: null,
    project_link: "https://emperiasmartsolutions.space",
    project_link_external: true,
  },
  {
    name: "Anushka: The Humanoid",
    description:
      "Anushka is a groundbreaking humanoid robot that redefines human-robot interactions with its lifelike appearance, ability to recognize faces, objects, and gestures as well as understand and respond to human speech in multiple languages.",
    tags: [
      {
        name: "AI and ML",
        color: "blue-text-gradient",
      },
      {
        name: "Embed",
        color: "green-text-gradient",
      },
      {
        name: "MERN",
        color: "pink-text-gradient",
      },
      {
        name: "OS Design",
        color: "orange-text-gradient",
      },
    ],
    image: piyushWithAnushka,
    source_code_link: "https://anushkathehumanoid.com",
    linked_link: "https://lnkd.in/p/gR9DaMWm",
    youtube_link: "https://www.youtube.com/watch?v=9i3s9a6siOM",
    project_link: "https://anushkathehumanoid.com",
    project_link_external: true,
  },
  {
    name: "Sunaina Robot",
    description:
      "A robotic Durga that served as the presiding figure at Chakraberia Sarbojanin Durgotsab, Kolkata, during Durga Puja 2025. Articulated gaze, neck and hand movement, built to be looked at by lakhs of people rather than operated by any of them.",
    tags: [
      { name: "Robotics", color: "blue-text-gradient" },
      { name: "Animatronics", color: "green-text-gradient" },
      { name: "Embedded C", color: "pink-text-gradient" },
    ],
    image: projSunaina,
    source_code_link: null,
    linked_link: null,
    youtube_link: "https://www.youtube.com/shorts/O_rsRYSI9NU",
    drive_link: "https://drive.google.com/file/d/1XzfQ7SS1-7GX4lQts9_zj4KDZqMoECw-/view?usp=sharing",
    project_link: "/project/sunaina",
    project_link_external: false,
  },
  {
    name: "DadaShree Robot",
    description:
      "A humanoid named with a relational honorific rather than a personal name — 'respected elder brother'. The naming is the interface: an Indian visitor already knows how to approach a Dada without being told.",
    tags: [
      { name: "Robotics", color: "blue-text-gradient" },
      { name: "HRI", color: "green-text-gradient" },
      { name: "Embedded", color: "pink-text-gradient" },
    ],
    image: projDadashree,
    source_code_link: null,
    linked_link: null,
    drive_link: "https://drive.google.com/file/d/10rDD39APFqbCoin4u9F7qHHlEE7ZUu_c/view?usp=sharing",
    project_link: "/project/dadashree",
    project_link_external: false,
  },
  {
    name: "GyrusGriham",
    description:
      "GyrusGriham is a Brain Controlled Home Automation System! An IoT project which employs MindWave headset to analyze brainwave signals and apply ML algorithms to estimate 'focus level' of the brain and trigger home automation appliances.",
    tags: [
      {
        name: "Android",
        color: "blue-text-gradient",
      },
      {
        name: "MERN",
        color: "green-text-gradient",
      },
      {
        name: "IoT",
        color: "pink-text-gradient",
      },
    ],
    image: brain,
    source_code_link: "https://github.com/piyush-khanna-qmb/Gyrus-Griham",
    linked_link: "https://lnkd.in/p/gNNr2JJK"
  },
  {
    name: "OptiTone",
    description:
      "OptiTone is a Computer Vision based volume controller for your PC. It lets you control your computer's audio system with simple hand gestures such as volume turn up/down, next/previous track, play/pause features with mapping from over 35 hand gestures.",
    tags: [
      {
        name: "OpenCV",
        color: "blue-text-gradient",
      },
      {
        name: "PyAutoGUI",
        color: "green-text-gradient",
      },
      {
        name: "PyCaw",
        color: "pink-text-gradient",
      },
    ],
    image: opti,
    source_code_link: "https://github.com/piyush-khanna-qmb/Hand-Volume-Control",
    linked_link: "https://lnkd.in/p/giH3ppBx"
  },
];

export { services, technologies, experiences, testimonials, projects };
export {
  pressReleases,
  pressSocial,
  publications,
  certificates,
  galleryPhotos,
} from "./content";
export { thoughts } from "./thoughts";
