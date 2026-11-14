export type OneOrMany = string | readonly string[] | null | undefined;

// Ruby's `Array(x).map(&:to_s).reject(&:empty?)`.
export function toList(value: OneOrMany): string[] {
  if (value === null || value === undefined) return [];
  const list = typeof value === "string" ? [value] : value;
  return list.map(String).filter((s) => s !== "");
}

export const toNumber = (value: unknown): number => Number(value ?? 0);
