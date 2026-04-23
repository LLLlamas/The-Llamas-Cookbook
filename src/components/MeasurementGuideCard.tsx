import { useMemo, useState } from 'react';
import {
  Pressable,
  StyleProp,
  StyleSheet,
  Text,
  View,
  ViewStyle,
} from 'react-native';
import { ChevronDown } from 'lucide-react-native';
import { colors } from '../theme/colors';
import { radius, spacing } from '../theme/spacing';
import { fontFamilies, textStyles } from '../theme/typography';
import {
  MEASUREMENT_GUIDE_SECTIONS,
  type MeasurementGuideSectionId,
} from '../lib/measurementConversions';

type Props = {
  defaultExpanded?: boolean;
  initialSection?: MeasurementGuideSectionId;
  style?: StyleProp<ViewStyle>;
};

export function MeasurementGuideCard({
  defaultExpanded = false,
  initialSection = 'cups',
  style,
}: Props) {
  const [expanded, setExpanded] = useState(defaultExpanded);
  const [activeSectionId, setActiveSectionId] =
    useState<MeasurementGuideSectionId>(initialSection);

  const activeSection = useMemo(
    () =>
      MEASUREMENT_GUIDE_SECTIONS.find((section) => section.id === activeSectionId) ??
      MEASUREMENT_GUIDE_SECTIONS[0],
    [activeSectionId],
  );

  return (
    <View style={[styles.card, style]}>
      <Pressable
        onPress={() => setExpanded((value) => !value)}
        style={({ pressed }) => [styles.header, pressed && styles.headerPressed]}
        accessibilityRole="button"
        accessibilityState={{ expanded }}
        accessibilityLabel="Toggle measurement help"
      >
        <View style={styles.headerCopy}>
          <Text style={styles.eyebrow}>Ingredients helper</Text>
          <Text style={styles.title}>Need a quick conversion?</Text>
          <Text style={styles.subtitle}>
            Cup, spoon, and metric swaps without leaving the ingredients list.
          </Text>
        </View>
        <View style={styles.chevronWrap}>
          <View style={expanded ? styles.chevronOpen : undefined}>
            <ChevronDown size={18} color={colors.textPrimary} strokeWidth={2.25} />
          </View>
        </View>
      </Pressable>

      {!expanded ? (
        <View style={styles.previewRow}>
          <View style={styles.previewChip}>
            <Text style={styles.previewText}>1 cup = 16 tbsp</Text>
          </View>
          <View style={styles.previewChip}>
            <Text style={styles.previewText}>1 tsp = 5 mL</Text>
          </View>
        </View>
      ) : (
        <View style={styles.body}>
          <Text style={styles.sectionDescription}>{activeSection.description}</Text>

          <View style={styles.segmentRow}>
            {MEASUREMENT_GUIDE_SECTIONS.map((section) => {
              const active = section.id === activeSection.id;
              return (
                <Pressable
                  key={section.id}
                  onPress={() => setActiveSectionId(section.id)}
                  style={[styles.segment, active && styles.segmentActive]}
                  accessibilityRole="button"
                  accessibilityState={{ selected: active }}
                  accessibilityLabel={`Show ${section.label.toLowerCase()} conversions`}
                >
                  <Text style={[styles.segmentText, active && styles.segmentTextActive]}>
                    {section.label}
                  </Text>
                </Pressable>
              );
            })}
          </View>

          <View style={styles.rows}>
            {activeSection.rows.map((row) => (
              <View key={row.amount} style={styles.row}>
                <Text style={styles.amount}>{row.amount}</Text>
                <View style={styles.equivalents}>
                  {row.equivalents.map((equivalent) => (
                    <View key={equivalent} style={styles.equivalentChip}>
                      <Text style={styles.equivalentText}>{equivalent}</Text>
                    </View>
                  ))}
                </View>
              </View>
            ))}
          </View>
        </View>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  card: {
    backgroundColor: colors.surface,
    borderRadius: radius.lg,
    borderWidth: 1,
    borderColor: colors.divider,
    overflow: 'hidden',
  },
  header: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: spacing.md,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.md,
  },
  headerPressed: {
    backgroundColor: colors.background,
  },
  headerCopy: {
    flex: 1,
    gap: 2,
  },
  eyebrow: {
    fontFamily: fontFamilies.bodySemibold,
    fontSize: 11,
    lineHeight: 14,
    color: colors.accent,
    textTransform: 'uppercase',
    letterSpacing: 0.8,
  },
  title: {
    fontFamily: fontFamilies.display,
    fontSize: 18,
    lineHeight: 24,
    color: colors.textPrimary,
  },
  subtitle: {
    ...textStyles.caption,
    color: colors.textSecondary,
  },
  chevronWrap: {
    width: 32,
    height: 32,
    borderRadius: radius.full,
    backgroundColor: colors.background,
    alignItems: 'center',
    justifyContent: 'center',
  },
  chevronOpen: {
    transform: [{ rotate: '180deg' }],
  },
  previewRow: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: spacing.xs,
    paddingHorizontal: spacing.md,
    paddingBottom: spacing.md,
  },
  previewChip: {
    paddingHorizontal: spacing.sm,
    paddingVertical: spacing.xs,
    borderRadius: radius.full,
    backgroundColor: colors.background,
    borderWidth: 1,
    borderColor: colors.divider,
  },
  previewText: {
    ...textStyles.caption,
    color: colors.textPrimary,
  },
  body: {
    gap: spacing.md,
    paddingHorizontal: spacing.md,
    paddingBottom: spacing.md,
  },
  sectionDescription: {
    ...textStyles.caption,
    color: colors.textSecondary,
  },
  segmentRow: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: spacing.xs,
  },
  segment: {
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.xs + 2,
    borderRadius: radius.full,
    backgroundColor: colors.background,
    borderWidth: 1,
    borderColor: colors.divider,
  },
  segmentActive: {
    backgroundColor: colors.accent,
    borderColor: colors.accent,
  },
  segmentText: {
    fontFamily: fontFamilies.bodyMedium,
    fontSize: 14,
    color: colors.textPrimary,
  },
  segmentTextActive: {
    color: '#FFFDF8',
  },
  rows: {
    gap: spacing.xs,
  },
  row: {
    gap: spacing.sm,
    padding: spacing.md,
    borderRadius: radius.md,
    backgroundColor: colors.background,
    borderWidth: 1,
    borderColor: colors.divider,
  },
  amount: {
    fontFamily: fontFamilies.bodySemibold,
    fontSize: 16,
    lineHeight: 20,
    color: colors.textPrimary,
    fontVariant: ['tabular-nums'],
  },
  equivalents: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: spacing.xs,
  },
  equivalentChip: {
    paddingHorizontal: spacing.sm,
    paddingVertical: spacing.xs,
    borderRadius: radius.full,
    backgroundColor: colors.surface,
    borderWidth: 1,
    borderColor: colors.divider,
  },
  equivalentText: {
    ...textStyles.caption,
    color: colors.textPrimary,
    fontVariant: ['tabular-nums'],
  },
});
