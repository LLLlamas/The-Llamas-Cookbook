import { useMemo, useState } from 'react';
import {
  FlatList,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { Plus } from 'lucide-react-native';
import type { NativeStackScreenProps } from '@react-navigation/native-stack';
import { useRecipesStore } from '../store/recipesStore';
import { EmptyState } from '../components/EmptyState';
import { RecipeCard } from '../components/RecipeCard';
import { colors } from '../theme/colors';
import { radius, shadow, spacing } from '../theme/spacing';
import { fontFamilies } from '../theme/typography';
import type { RootStackParamList } from '../navigation/RootStack';

type Props = NativeStackScreenProps<RootStackParamList, 'Library'>;

export function LibraryScreen({ navigation }: Props) {
  const hydrated = useRecipesStore((s) => s.hydrated);
  const recipes = useRecipesStore((s) => s.recipes);

  const list = useMemo(
    () =>
      Object.values(recipes).sort((a, b) =>
        b.createdAt.localeCompare(a.createdAt),
      ),
    [recipes],
  );

  const allTags = useMemo(() => {
    const set = new Set<string>();
    for (const r of list) for (const t of r.tags) set.add(t);
    return Array.from(set).sort((a, b) => a.localeCompare(b));
  }, [list]);

  const [activeTag, setActiveTag] = useState<string | null>(null);

  const filtered = useMemo(
    () => (activeTag ? list.filter((r) => r.tags.includes(activeTag)) : list),
    [list, activeTag],
  );

  const openEditor = () => navigation.navigate('RecipeEditor', {});

  if (!hydrated) {
    return <View style={styles.container} />;
  }

  const showFilter = allTags.length > 0;

  return (
    <View style={styles.container}>
      {showFilter ? (
        <View style={styles.filterBar}>
          <ScrollView
            horizontal
            showsHorizontalScrollIndicator={false}
            contentContainerStyle={styles.filterStrip}
          >
            <FilterChip
              label={`All${list.length > 0 ? `  ·  ${list.length}` : ''}`}
              active={activeTag === null}
              onPress={() => setActiveTag(null)}
            />
            {allTags.map((tag) => {
              const count = list.filter((r) => r.tags.includes(tag)).length;
              return (
                <FilterChip
                  key={tag}
                  label={`${tag}  ·  ${count}`}
                  active={activeTag === tag}
                  onPress={() =>
                    setActiveTag((prev) => (prev === tag ? null : tag))
                  }
                />
              );
            })}
          </ScrollView>
        </View>
      ) : null}

      {list.length === 0 ? (
        <EmptyState
          title="No recipes yet"
          subtitle="Tap the + button to add your first recipe."
        />
      ) : filtered.length === 0 ? (
        <View style={styles.emptyFilter}>
          <Text style={styles.emptyFilterTitle}>
            No recipes tagged "{activeTag}"
          </Text>
          <Pressable
            onPress={() => setActiveTag(null)}
            style={styles.clearBtn}
          >
            <Text style={styles.clearBtnText}>Clear filter</Text>
          </Pressable>
        </View>
      ) : (
        <FlatList
          data={filtered}
          keyExtractor={(r) => r.id}
          contentContainerStyle={styles.listContent}
          ItemSeparatorComponent={() => <View style={styles.sep} />}
          renderItem={({ item }) => (
            <RecipeCard
              recipe={item}
              onPress={() => navigation.navigate('RecipeDetail', { id: item.id })}
            />
          )}
        />
      )}
      <Pressable
        accessibilityLabel="Add recipe"
        style={({ pressed }) => [styles.fab, pressed && styles.fabPressed]}
        onPress={openEditor}
      >
        <Plus color="#FFFDF8" size={28} strokeWidth={2.25} />
      </Pressable>
    </View>
  );
}

type FilterChipProps = {
  label: string;
  active: boolean;
  onPress: () => void;
};

function FilterChip({ label, active, onPress }: FilterChipProps) {
  return (
    <Pressable
      onPress={onPress}
      style={[styles.chip, active && styles.chipActive]}
      accessibilityLabel={`Filter ${label}`}
    >
      <Text style={[styles.chipText, active && styles.chipTextActive]}>
        {label}
      </Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: colors.background,
  },
  filterBar: {
    borderBottomWidth: 1,
    borderBottomColor: colors.divider,
    backgroundColor: colors.background,
  },
  filterStrip: {
    flexDirection: 'row',
    gap: spacing.xs,
    paddingHorizontal: spacing.lg,
    paddingVertical: spacing.sm,
  },
  chip: {
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.xs + 2,
    borderRadius: radius.full,
    backgroundColor: colors.surface,
    borderWidth: 1,
    borderColor: colors.divider,
  },
  chipActive: {
    backgroundColor: colors.accent,
    borderColor: colors.accent,
  },
  chipText: {
    fontFamily: fontFamilies.bodyMedium,
    fontSize: 13,
    color: colors.textPrimary,
  },
  chipTextActive: {
    color: '#FFFDF8',
  },
  listContent: {
    padding: spacing.lg,
  },
  sep: {
    height: spacing.md,
  },
  emptyFilter: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: spacing.xl,
    gap: spacing.md,
  },
  emptyFilterTitle: {
    fontFamily: fontFamilies.display,
    fontSize: 18,
    color: colors.textPrimary,
    textAlign: 'center',
  },
  clearBtn: {
    paddingHorizontal: spacing.lg,
    paddingVertical: spacing.sm,
    borderRadius: radius.md,
    backgroundColor: colors.surface,
    borderWidth: 1,
    borderColor: colors.divider,
  },
  clearBtnText: {
    fontFamily: fontFamilies.bodySemibold,
    fontSize: 14,
    color: colors.accent,
  },
  fab: {
    position: 'absolute',
    right: spacing.xl,
    bottom: spacing.xl,
    width: 60,
    height: 60,
    borderRadius: radius.full,
    backgroundColor: colors.accent,
    alignItems: 'center',
    justifyContent: 'center',
    ...shadow.card,
  },
  fabPressed: {
    opacity: 0.85,
  },
});
