import { useState } from 'react';
import { StyleSheet, TextInput, View } from 'react-native';
import { colors } from '../theme/colors';
import { radius, spacing } from '../theme/spacing';
import { textStyles } from '../theme/typography';
import { TagChip } from './TagChip';

type Props = {
  tags: string[];
  onChange: (tags: string[]) => void;
};

export function TagInput({ tags, onChange }: Props) {
  const [draft, setDraft] = useState('');

  const commit = () => {
    const cleaned = draft.trim().toLowerCase().replace(/^#/, '');
    if (!cleaned) return;
    if (tags.includes(cleaned)) {
      setDraft('');
      return;
    }
    onChange([...tags, cleaned]);
    setDraft('');
  };

  const remove = (tag: string) => {
    onChange(tags.filter((t) => t !== tag));
  };

  return (
    <View style={styles.container}>
      <View style={styles.chipsRow}>
        {tags.map((tag) => (
          <TagChip key={tag} label={tag} onRemove={() => remove(tag)} />
        ))}
      </View>
      <TextInput
        value={draft}
        onChangeText={setDraft}
        onSubmitEditing={commit}
        onBlur={commit}
        placeholder="Add tag (e.g. dinner)"
        placeholderTextColor={colors.textSecondary}
        style={styles.input}
        returnKeyType="done"
        autoCapitalize="none"
        autoCorrect={false}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    gap: spacing.sm,
  },
  chipsRow: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: spacing.xs,
  },
  input: {
    ...textStyles.body,
    color: colors.textPrimary,
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: colors.divider,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
  },
});
