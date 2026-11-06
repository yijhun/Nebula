import { describe, expect, it } from "vitest";
import { guessCiteLabel } from "../citeLabel.js";

describe("guessCiteLabel", () => {
  it("takes the year from the end of the key, not the first 4 digits", () => {
    expect(guessCiteLabel("sandellNGC7538IRS1an2020a")).toBe("Sandell (2020)");   // was "Sandell (7538)"
    expect(guessCiteLabel("milam12C13CIsotope2005")).toBe("Milam (2005)");
    expect(guessCiteLabel("wrightNGC7538IRS2014")).toBe("Wright (2014)");
  });
  it("handles plain keys and same-year suffixes", () => {
    expect(guessCiteLabel("lugoPhotoevaporatedDisksMassive2004b")).toBe("Lugo (2004)");
    expect(guessCiteLabel("rybickiRadiativeProcessesAstrophysics1979")).toBe("Rybicki (1979)");
  });
  it("falls back to a year elsewhere, or to the key itself", () => {
    expect(guessCiteLabel("smith2019review")).toBe("Smith (2019)");
    expect(guessCiteLabel("NGC7538")).toBe("NGC7538");                     // 7538 is not a year
    expect(guessCiteLabel("noyearkey")).toBe("noyearkey");
  });
});
