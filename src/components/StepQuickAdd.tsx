import { useRef, useState } from 'react';
import { StyleSheet, TextInput, View } from 'react-native';
import { colors } from '../theme/colors';
import { radius, spacing } from '../theme/spacing';
import { textStyles } from '../theme/typography';
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
      <TextInput
        ref={inputRef}
        value={text}
        onChangeText={setText}
        placeholder={`Step ${nextNumber}`}
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
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    padding: spacing.sm,
    borderWidth: 1,
    borderColor: colors.divider,
  },
  input: {
    ...textStyles.body,
    color: colors.textPrimary,
    paddingVertical: spacing.sm,
    paddingHorizontal: spacing.sm,
    minHeight: 40,
  },
});
