# Opposition Report

**Thesis:** *An Information Security Vendor Assessment Framework for AI Procurement*
**Authors:** Lukas Bängs & Michel Messo
**Programme:** Master's Programme in Computer and Information Engineering, Uppsala University
**Opponent:** Fredrik Hammarberg
**Date:** 2026-06-03

---

## 1. Summary of the Thesis

This thesis addresses a practical gap in information security governance: ISO 27001's supplier assessment controls are technology-neutral and do not guide customers for AI-specific risks when procuring AI products. This thesis develops a vendor assessment framework (VAF) using the Design Science Research (DSR) methodology. The framework classifies AI products along two axes: operational autonomy and data sensitivity. This is done to assign the product one of two assessment tiers (Baseline or Deeper Diligence). The framework then provides 18 baseline and 13 deeper-diligence questions, each mapped to the CIA triad and accompanied by evaluation guidance. The framework is evaluated through two illustrative scenarios applying it to Miro AI (a Human-in-the-Loop product) and Claude CoWork (an autonomous agent), demonstrating that the classification mechanism produces meaningfully different assessments.

---

## 2. Readability, Clarity, and Disposition

**Overall impression:** The report is well-written, logically structured, and largely accessible to a reader without deep AI expertise. The language is clear and professional throughout. A few specific comments follow.

**Method and Results overlap:** The Method chapter (Chapter 3) and the Results chapter (Chapter 4) feel uncomfortably redundant in practice. Section 3.2.3 (Step 3 - Design and Development) already explains *why* operational autonomy was chosen as an axis, *why* data sensitivity was included, *why* the highest-watermark principle was adopted, *how* questions were split into tiers, and *why* evaluation guidance was added. By the time the reader reaches Chapter 4, the design rationale has already been communicated. Chapter 4 then re-presents the same classification logic (Section 4.2) and question structure (Section 4.3) largely without adding new substance beyond formatting the framework itself.

**Figures:** Figure 2 (the classification process) conveys the two-axis classification mechanism clearly. However, the text is small and the layout is too spacious, making it difficult to read. Creating an actual 2D matrix with all 12 cells visible would be more effective. These cells could then be colour-coded to show which classification each cell maps to (Baseline or Deeper Diligence). Figure 1 also suffers from very small text making it hard to read.

---

## 3. Scientific Content — Comments and Questions

### 3.1 Research Questions and Aims

The two research questions are clearly formulated and appropriately scoped.

### 3.2 The Classification Mechanism

The two-axis classification (operational autonomy and data sensitivity) is a great way of classification.

**Question:** Could the assessment matrix be expanded to more dimensions — for example adding a third axis for integration depth or data volume — and if so, what would that require of the framework?

**Question:** Could the assessment matrix be split into more than just Baseline and Deeper Diligence? A three-tier structure might better reflect the difference between a D2-HITL and a D4-Autonomous product, both of which currently receive the same 13-question deeper-diligence questionnaire.

### 3.3 The Assessment Framework

**Question:** What in the framework would need to change in order to enable a concrete procurement decision, rather than a set of findings the assessor must still weigh themselves?

**Question:** Silent model updates are described as a general risk affecting all AI products (Section 2.4.2), yet the reassessment question is only part of the Deeper Diligence questions. Is there a reason this question is not included in the Baseline tier?

### 3.4 Evaluation

The evaluation is well-designed to demonstrate the framework's ability to produce different assessments for different products as well as showcase how the framework is used in practice.

### 3.5 Discussion, conclusion, and future work
The discussion and conclusion sections are well-argued and appropriately acknowledge the limitations of the work. The future work section is realistic and provides a clear roadmap for how the framework can be further developed and validated.
---

## 4. Minor Errors and Formal Criteria

The PDF contains annotations discussing minor errors. None were found that significantly impacted the overall quality of the thesis.

**Abbreviations:** The thesis uses several abbreviations that are not always defined on first use, the list of abbreviations on page 3 is helpful but definitions should also be provided in the text. FUrthermore the expansion of some abbreviations is inconsistent (e.g. "HITL" is expanded as "Human-in-the-Loop" in some places but Human-In-The-Loop in others).

---

## 5. Collective Evaluation

**Areas for improvement:**

The absence of independent user testing leaves O4 (practitioner accessibility) only partially validated. This is honestly acknowledged but remains a significant limitation.

The framework surfaces findings but provides no threshold for when those findings are serious enough to recommend against procurement or require contractual remedies. For non-AI-specialists (O4), this shifts the hardest decision entirely to the assessor's personal judgement. This is somewhat acknowledged and somewhat mitigated by the "What a good answer looks like" guidance.

**Strengths:**

The core conceptual contribution — adding operational autonomy as a second classification axis alongside data sensitivity — is well-argued and not found in existing frameworks.

The "Why it matters" and "What a good answer looks like" guidance for each question directly addresses the practitioner accessibility objective, translating AI-specific technical risks into assessable questions for non-specialists.

Overall, this is a practically motivated, clearly written thesis that makes a genuine contribution to AI procurement governance.