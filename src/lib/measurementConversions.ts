export type MeasurementGuideSectionId = 'cups' | 'spoons' | 'metric';

export type MeasurementGuideRow = {
  amount: string;
  equivalents: string[];
};

export type MeasurementGuideSection = {
  id: MeasurementGuideSectionId;
  label: string;
  description: string;
  rows: MeasurementGuideRow[];
};

export const MEASUREMENT_GUIDE_SECTIONS: MeasurementGuideSection[] = [
  {
    id: 'cups',
    label: 'Cups',
    description:
      'Standard cup sets are usually 1/4, 1/3, 1/2, and 1 cup. Use spoon swaps for the in-between amounts.',
    rows: [
      { amount: '1/8 cup', equivalents: ['2 tbsp', '6 tsp', '30 mL'] },
      { amount: '1/4 cup', equivalents: ['4 tbsp', '60 mL'] },
      { amount: '1/3 cup', equivalents: ['5 tbsp + 1 tsp', '80 mL'] },
      { amount: '3/8 cup', equivalents: ['1/4 cup + 2 tbsp', '90 mL'] },
      { amount: '1/2 cup', equivalents: ['8 tbsp', '120 mL'] },
      { amount: '5/8 cup', equivalents: ['1/2 cup + 2 tbsp', '150 mL'] },
      { amount: '2/3 cup', equivalents: ['10 tbsp + 2 tsp', '160 mL'] },
      { amount: '3/4 cup', equivalents: ['12 tbsp', '180 mL'] },
      { amount: '7/8 cup', equivalents: ['3/4 cup + 2 tbsp', '210 mL'] },
      { amount: '1 cup', equivalents: ['16 tbsp', '240 mL'] },
    ],
  },
  {
    id: 'spoons',
    label: 'Spoons',
    description: 'Quick spoon math for the amounts most recipes bounce between.',
    rows: [
      { amount: '1 tsp', equivalents: ['5 mL'] },
      { amount: '1 1/2 tsp', equivalents: ['1/2 tbsp'] },
      { amount: '3 tsp', equivalents: ['1 tbsp', '15 mL'] },
      { amount: '2 tbsp', equivalents: ['1/8 cup', '30 mL'] },
      { amount: '4 tbsp', equivalents: ['1/4 cup', '60 mL'] },
      { amount: '8 tbsp', equivalents: ['1/2 cup', '120 mL'] },
    ],
  },
  {
    id: 'metric',
    label: 'Metric',
    description: 'Helpful when a recipe jumps between U.S. and metric measurements.',
    rows: [
      { amount: '5 mL', equivalents: ['1 tsp'] },
      { amount: '15 mL', equivalents: ['1 tbsp'] },
      { amount: '60 mL', equivalents: ['1/4 cup'] },
      { amount: '125 mL', equivalents: ['1/2 cup'] },
      { amount: '250 mL', equivalents: ['1 cup'] },
      { amount: '500 mL', equivalents: ['2 cups', '1 pint'] },
    ],
  },
];
