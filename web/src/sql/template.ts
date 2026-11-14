// Same {{name}} / {{name*}} / {{#name}}...{{/name}} syntax as TrainDelayMetrics::Sql.expand;
// both are checked against spec/shared/sql_template_cases.json.
export type Params = Record<string, unknown>;

export class TemplateError extends Error {}

const SECTION = /\{\{#(\w+)\}\}([\s\S]*?)\{\{\/\1\}\}/g;
const MARKER = /\{\{(\w+)(\*?)\}\}/g;
const SECTION_TAG = /\{\{[#/]/;

export function isPresent(value: unknown): boolean {
  return !(value === null || value === undefined || (Array.isArray(value) && value.length === 0));
}

export function expand(text: string, params: Params): { sql: string; binds: unknown[] } {
  const sectioned = text.replace(SECTION, (_match, name: string, body: string) => {
    if (SECTION_TAG.test(body)) throw new TemplateError(`nested section inside {{#${name}}}`);
    return isPresent(params[name]) ? body : "";
  });
  if (SECTION_TAG.test(sectioned)) throw new TemplateError("unbalanced section marker");

  const binds: unknown[] = [];
  const sql = sectioned.replace(MARKER, (_match, name: string, star: string) => {
    const value = params[name];
    if (star === "*") {
      if (!Array.isArray(value) || value.length === 0) {
        throw new TemplateError(`{{${name}*}} needs a non-empty array`);
      }
      binds.push(...value);
      return value.map(() => "?").join(", ");
    }
    if (value === null || value === undefined) throw new TemplateError(`missing param ${name}`);
    binds.push(value);
    return "?";
  });

  return { sql, binds };
}
