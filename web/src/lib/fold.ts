// Same map as Slug::TRANSLIT, so "köln" and "koeln" both fold to "koeln".
const TRANSLIT: Record<string, string> = {
  ä: "ae",
  ö: "oe",
  ü: "ue",
  Ä: "Ae",
  Ö: "Oe",
  Ü: "Ue",
  ß: "ss",
};

export function fold(value: string): string {
  return value.normalize("NFC").replace(/[äöüÄÖÜß]/g, (ch) => TRANSLIT[ch]).toLowerCase();
}
