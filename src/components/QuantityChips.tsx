import { Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { colors } from '../theme/colors';
import { radius, spacing } from '../theme/spacing';
import { fontFamilies } from '../theme/typography';

const WHOLES = ['1', '2', '3', '4', '5', '6', '8', '10', '12'];
const FRACS = ['1/8', '1/4', '1/3', '1/2', '2/3', '3/4'];

type Parsed = { whole?: string; frac?: string; freeform: boolean };

function parseQty(v: string): Parsed {
  const t = v.trim();
  if (!t) return { freeform: false };
  const mixed = t.match(/^(\d+)\s+(\d+\/\d+)$/);
  if (mixed) return { whole: mixed[1], frac: mixed[2], freeform: false };
  const fracOnly = t.match(/^(\d+\/\d+)$/);
  if (fracOnly) return { frac: fracOnly[1], freeform: false };
  const wholeOnly = t.match(/^(\d+)$/);
  if (wholeOnly) return { whole: wholeOnly[1], freeform: false };
  return { freeform: true };
}

function combine(whole: string | undefined, frac: string | undefined): string {
  return [whole, frac].filter(Boolean).join(' ');
}

type Props = {
  value: string;
  onChange: (next: string) => void;
};

export function QuantityChips({ value, onChange }: Props) {
  const parsed = parseQty(value);

  const pickWhole = (n: string) => {
    if (parsed.freeform) {
      onChange(n);
      return;
    }
    const nextWhole = parsed.whole === n ? undefined : n;
    onChange(combine(nextWhole, parsed.frac));
  };

  const pickFrac = (f: string) => {
    if (parsed.freeform) {
      onChange(f);
      return;
    }
    const nextFrac = parsed.frac === f ? undefined : f;
    onChange(combine(parsed.whole, nextFrac));
  };

  return (
    <View style={styles.wrap}>
      <ScrollView
        horizontal
        showsHorizontalScrollIndicator={false}
        keyboardShouldPersistTaps="always"
        contentContainerStyle={styles.strip}
      >
        {WHOLES.map((n) => {
          const active = !parsed.freeform && parsed.whole === n;
          return (
            <Pressable
              key={`w-${n}`}
              onPress={() => pickWhole(n)}
              style={[styles.chip, styles.wholeChip, active && styles.chipActive]}
              accessibilityLabel={`Add whole number ${n}`}
            >
              <Text
                style={[
                  styles.text,
                  styles.wholeText,
                  active && styles.textActive,
                ]}
              >
                {n}
              </Text>
            </Pressable>
          );
        })}
      </ScrollView>
      <ScrollView
        horizontal
        showsHorizontalScrollIndicator={false}
        keyboardShouldPersistTaps="always"
        contentContainerStyle={styles.strip}
      >
        {FRACS.map((f) => {
          const active = !parsed.freeform && parsed.frac === f;
          return (
            <Pressable
              key={`f-${f}`}
              onPress={() => pickFrac(f)}
              style={[styles.chip, active && styles.chipActive]}
              accessibilityLabel={`Add fraction ${f}`}
            >
              <Text style={[styles.text, active && styles.textActive]}>{f}</Text>
            </Pressable>
          );
        })}
      </ScrollView>
    </View>
  );
}

const styles = StyleSheet.create({
  wrap: {
    gap: 2,
  },
  strip: {
    flexDirection: 'row',
    gap: spacing.xs,
    paddingVertical: spacing.xs,
  },
  chip: {
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.xs + 2,
    borderRadius: radius.full,
    backgroundColor: colors.surface,
    borderWidth: 1,
    borderColor: colors.divider,
    minWidth: 40,
    alignItems: 'center',
    justifyContent: 'center',
  },
  wholeChip: {
    minWidth: 44,
  },
  chipActive: {
    backgroundColor: colors.accent,
    borderColor: colors.accent,
  },
  text: {
    fontFamily: fontFamilies.bodyMedium,
    fontSize: 14,
    color: colors.textPrimary,
    fontVariant: ['tabular-nums'],
  },
  wholeText: {
    fontFamily: fontFamilies.bodySemibold,
    fontSize: 16,
  },
  textActive: {
    color: '#FFFDF8',
  },
});
