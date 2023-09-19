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
  tpp,
  wipro,
  auto,
  mbs,
  carrent,
  jobit,
  tripguide,
  threejs,
  android,
  ocv,
  unity,
  tf,
  ros,
  esp,
  rasp,
  java,
  py,
  anushka,
  tppi,
  brain,
  nfs,
  diary,
  bulk,
  AR,
  bin,
  opti,
  hodWala,
  mbsWala,
  tppWala,
  deanWala
} from "../assets";

export const navLinks = [
  {
    id: "about",
    title: "About",
  },
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
    name: "ESP",
    icon: esp,
  },
  {
    name: "Android",
    icon: android,
  },
  {
    name: "Raspberry Pi",
    icon: rasp,
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
      "Reinforced and enhanced the design of Oxyana- Oxygen Concentrator for Soldiers, a patented product of MBS India.",
      "Researched in the field of applying Machine Learning to filter out noisy signals in heartbeat and pulse forms. Also Engineered a design for smart stethoscope using the same technology.",
      "Implementing responsive design and ensuring cross-browser compatibility.",
      "Participating in code reviews and providing constructive feedback to other developers.",
    ],
  },
  {
    title: "Frontend developer",
    company_name: "Teerth Purohit Prayagraj",
    icon: tpp,
    iconBg: "#E6DEDD",
    date: "Sept 2021 - Nov 2021",
    points: [
      "Designed the company's portfolio website with frontend using HTML, CSS and JS with integrated map, contacts and social links.",

      "Increased their approach manifolds.",
    ],
  },
  {
    title: "Full Stack Web Developer",
    company_name: "MBS India",
    icon: mbs,
    iconBg: "#E6DEDD",
    date: "Jan 2022 - Mar 2022",
    points: [
      "Designed and developed a fullstack portfolio website for the company with frontend designed in ReactJS and backend support of NodeJS, ExpressJS and MongoDB for database with mongoose integration.",
      "It includes product display Index and the functionality to place order for respective products with payment portal support.",
      "The website doubled the sales of the company's products within 2 months of publishing with SEO manipulation."
    ],
  },
  {
    title: "Summer Intern",
    company_name: "Wipro",
    icon: wipro,
    iconBg: "#E6DEDD",
    date: "May 2022 - Sept 2022",
    points: [
      "Successfully completed a comprehensive online training program in Project-Based Learning under the esteemed Wipro Talent Next - Future Skills Program, spanning from May to September 2022.",
      "This training not only enhanced my understanding of project-driven methodologies but also equipped me with valuable skills essential for the ever-evolving tech landscape."
    ],
  },
  {
    title: "Project Intern",
    company_name: "Automation Anywhere",
    icon: auto,
    iconBg: "#E6DEDD",
    date: "Sept 2022 - Nov 2022",
    points: [
      "Completed the 'Empowering Your Workforce with Robotic Process Automation (RPA)' Learning Trail from Automation Anywhere University.",
      "This training has equipped me with valuable skills and knowledge to excel in the field of Robotics Process Automation."
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
    name: "Anushka",
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
    image: anushka,
    source_code_link: "https://github.com/",
    linked_link: "https://linkedin.com/"
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
    linked_link: "https://linkedin.com/"
  },
  {
    name: "The Gamchha Diary",
    description:
      "The gamchha Diary is a MERN stack-powered blog website that offers fast and secure content retrieval while adding a personal touch with customizable themes and interactive elements. Effortlessly embed multimedia, and craft engaging narratives.",
    tags: [
      {
        name: "ReactJS",
        color: "blue-text-gradient",
      },
      {
        name: "MongoDB",
        color: "green-text-gradient",
      },
      {
        name: "ExpressJS",
        color: "pink-text-gradient",
      },
    ],
    image: diary,
    source_code_link: "https://github.com/piyush-khanna-qmb/Blog-Site",
    linked_link: "https://linkedin.com/"
  },
  {
    name: "SIGMA",
    description:
      "Synchronized Interface for Gaming Machine Augmentation is a gaming simulator made using set of actuators such as joystick, rotary encoders and embedded systems interfaced with PC using pyserial library for precise and accurate driving simulation.",
    tags: [
      {
        name: "Embedded C",
        color: "blue-text-gradient",
      },
      {
        name: "Python",
        color: "green-text-gradient",
      },
      {
        name: "Computer Vision",
        color: "pink-text-gradient",
      },
    ],
    image: nfs,
    source_code_link: "https://github.com/piyush-khanna-qmb/I-am-Speed",
    linked_link: "https://linkedin.com/"
  },
  {
    name: "Pigrazzi",
    description:
      "Pigrazzi introduces a paradigm shift in web media retrieval. It simplifies bulk image downloads while offering customization options for visuals, saving you precious time and fostering tech creativity at your fingertips.",
    tags: [
      {
        name: "GUI Automation",
        color: "blue-text-gradient",
      },
      {
        name: "Bash Curl",
        color: "green-text-gradient",
      },
      {
        name: "Python",
        color: "pink-text-gradient",
      },
    ],
    image: bulk,
    source_code_link: "https://github.com/piyush-khanna-qmb/Zucc-Snucc",
    linked_link: "https://linkedin.com/"
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
    linked_link: "https://linkedin.com/"
  },
  {
    name: "Teerth Purohit Prayagraj",
    description:
      "This simple portfolio project enhances marketing and customer interaction for the temple purohit. Created with WhatsApp, Instagram, maps, and email functionalities, it boosted their family profession's marketing and customer engagement significantly.",
    tags: [
      {
        name: "HTML",
        color: "blue-text-gradient",
      },
      {
        name: "CSS",
        color: "green-text-gradient",
      },
      {
        name: "Javascript",
        color: "pink-text-gradient",
      },
    ],
    image: tppi,
    source_code_link: "https://piyush-khanna-qmb.github.io/TeerthPurohitPrayagraj/",
    linked_link: "https://linkedin.com/"
  },

  {
    name: "AR4U",
    description:
      "AR_4_U, powered by Unity, revolutionizes Augmented Reality content creation. Import custom or library-based 3D models and let its advanced machine learning capabilities automatically suggest lifelike movements for various parts of your models.",
    tags: [
      {
        name: "Unity",
        color: "blue-text-gradient",
      },
      {
        name: "Vuforia",
        color: "green-text-gradient",
      },
      {
        name: "Machine Learning",
        color: "pink-text-gradient",
      },
    ],
    image: AR,
    source_code_link: "https://github.com/piyush-khanna-qmb/AR-4-U",
    linked_link: "https://linkedin.com/"
  },
  {
    name: "BinGenius",
    description:
      "BinGenius is your smart waste management companion. With its advanced sensors and AI-driven technology, BinMinder knows when it's full, compacts trash for more space, alerts the collection service when it's time for pickup and even helps you sort recyclables.",
    tags: [
      {
        name: "IoT",
        color: "blue-text-gradient",
      },
      {
        name: "Embedded C",
        color: "green-text-gradient",
      },
      {
        name: "Bash",
        color: "pink-text-gradient",
      },
    ],
    image: bin,
    source_code_link: "https://github.com/piyush-khanna-qmb/Koodha-Daan",
    linked_link: "https://linkedin.com/"
  },
];

export { services, technologies, experiences, testimonials, projects };
