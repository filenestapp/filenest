const fileNestWorkflowData = [
  {
    id: "indexing",
    label: "Indexing",
    title: "Library",
    subtitle: "Search and manage organized files; all indexes stay on this Mac.",
  },
  {
    id: "search",
    label: "Search",
    title: "Library",
    subtitle: "Search and manage organized files; all indexes stay on this Mac.",
  },
  {
    id: "smart",
    label: "Smart Search",
    title: "Library",
    subtitle: "Search and manage organized files; all indexes stay on this Mac.",
  },
  {
    id: "find-chat",
    label: "Find with Chat",
    title: "Find with Chat",
    subtitle: "Ask about your library and get answers grounded in matching files.",
  },
  {
    id: "file-chat",
    label: "Chat with File",
    title: "Chat with File",
    subtitle: "Analyze only the current file without mixing in content from the library.",
  },
];

const fileNestMockFiles = [
  {
    name: "Aurora Product Brief.pdf",
    path: "~/Northstar Studio/Project Aurora/Strategy",
    type: "pdf",
    category: "Documents",
    size: "2.4 MB",
    modified: "Jul 16, 10:42 AM",
    confidence: "Best Match",
  },
  {
    name: "Customer Research Synthesis.docx",
    path: "~/Northstar Studio/Research",
    type: "word",
    category: "Documents",
    size: "846 KB",
    modified: "Jul 15, 4:18 PM",
    confidence: "Strong Match",
  },
  {
    name: "Spring Offsite — Aurora Packaging.pptx",
    path: "~/Northstar Studio/Offsites/2026",
    type: "slides",
    category: "Presentations",
    size: "8.1 MB",
    modified: "Apr 24, 3:06 PM",
    confidence: "93% Match",
  },
  {
    name: "Launch Budget.xlsx",
    path: "~/Northstar Studio/Project Aurora/Operations",
    type: "sheet",
    category: "Spreadsheets",
    size: "314 KB",
    modified: "Jul 14, 9:12 AM",
    confidence: "Related",
  },
];

const fileNestDirections = [
  {
    id: "native-stage",
    short: "A",
    name: "Native Product Stage",
    note: "Selected · native UI with local-AI trust",
  },
  {
    id: "product-first",
    short: "B",
    name: "Product-First Canvas",
    note: "The live app becomes the hero",
  },
  {
    id: "privacy-proof",
    short: "C",
    name: "Privacy as Proof",
    note: "A darker trust-led launch direction",
  },
];

Object.assign(window, {
  fileNestWorkflowData,
  fileNestMockFiles,
  fileNestDirections,
});
