import { useRef, useState } from 'react';
import { StyleSheet, Text, TextInput, View } from 'react-native';
import { colors } from '../theme/colors';
import { radius, spacing } from '../theme/spacing';
import { fontFamilies, textStyles } from '../theme/typography';
import { newId } from '../lib/ids';
import type { Step } from '../types/recipe';

type Props = {
  onAdd: (step: Omit<Step, 'order'>) => void;
  nextNumber: number;
};

export function StepQuickAdd({ onAdd, nextNumber }: Props) {
  const [text, setText] = useState('');
  const inputRef = useRef<TextInput>(null);

  const submit = () => {
    const trimmed = text.trim();
    if (!trimmed) return;
    onAdd({ id: newId(), text: trimmed });
    setText('');
    inputRef.current?.focus();
  };

  return (
    <View style={styles.row}>
      <View style={styles.numberBadge}>
        <Text style={styles.numberText}>{nextNumber}</Text>
      </View>
      <TextInput
        ref={inputRef}
        value={text}
        onChangeText={setText}
        placeholder={`Describe step ${nextNumber}…`}
        placeholderTextColor={colors.textSecondary}
        style={styles.input}
        returnKeyType="done"
        blurOnSubmit={false}
        multiline
        onSubmitEditing={submit}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  row: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: spacing.sm,
  },
  numberBadge: {
    width: 36,
    height: 44,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: colors.divider,
  },
  numberText: {
    fontFamily: fontFamilies.displayBold,
    fontSize: 16,
    color: colors.accent,
    fontVariant: ['tabular-nums'],
  },
  input: {
    ...textStyles.body,
    flex: 1,
    color: colors.textPrimary,
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: colors.divider,
    paddingVertical: spacing.sm,
    paddingHorizontal: spacing.md,
    minHeight: 44,
    textAlignVertical: 'top',
  },
});
