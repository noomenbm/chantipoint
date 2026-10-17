# Questions client - ChantiPoint v0.1

Ce document interne sert à préparer une discussion de validation. Il ne constitue pas une approbation du client et ne doit pas être envoyé tel quel.

## Points compris comme établis pour la planification

Ces points sont traités comme des exigences rapportées pour la planification, mais ils devront être confirmés dans une spécification approuvée.

1. L'application ChantiPoint doit être en français.
2. Le pilote vise d'abord Android; iOS demeure une cible future.
3. L'application doit enregistrer les pointages manuels d'entrée et de sortie.
4. La cible de développement M2.3b supprime le choix d'un mode faisant autorité par l'employé; le serveur classera les indices comme usine, chantier extérieur ou localisation non vérifiée.
5. La cible prévoit une tentative de localisation au premier plan à l'entrée et à la sortie, y compris à l'usine. Des indices absents ou insuffisants ne bloqueront pas un pointage autrement autorisé; ils entraîneront un motif technique et une révision.
6. Les résultats de localisation à l'entrée et à la sortie sont indépendants. Le géorepérage et la surveillance restent des fonctions ultérieures distinctes, soumises à validation et autorisation.
7. La localisation sert à fournir des indices liés au téléphone, sans prétendre prouver la présence physique ou la productivité de l'employé.
8. La paie est exclue de la V1; les totaux d'heures travaillées par mois et l'export CSV opérationnel sont requis.
9. Les rapports quotidiens et hebdomadaires sont des améliorations possibles, pas des livrables V1 confirmés.
10. Un administrateur désigné examine initialement les sessions, anomalies, fermetures automatiques proposées et demandes de correction.
11. Des administrateurs additionnels pourront être ajoutés plus tard, sans obliger une gestion complexe dès la V1.
12. L'employeur est responsable de l'avis aux employés, de la politique de surveillance, de l'EFVP et des validations légales ou RH.
13. Pour les corrections de pointage, l'employé peut fournir une explication simple; l'administrateur désigné exerce le jugement et prend la décision.
14. Le géorepérage demeure le candidat technique privilégié pour les chantiers extérieurs, sous réserve de faisabilité.
15. Les paramètres proposés sont un rayon de 100 à 150 m et un délai de grâce de 10 minutes après la réception fiable d'un événement de sortie.
16. Après 8 heures de session active, l'employé doit recevoir une notification avec `Terminer la session` et `Continuer la session`.
17. Ces points ne constituent pas une approbation écrite formelle du client. Le développeur a approuvé la cible révisée M2.3b pour le développement; M2.3b.1 prépare seulement le schéma, sans nouveaux RPC ni acquisition Flutter. L'approbation client/vie privée reste nécessaire avant tout déploiement auprès de vrais employés.
18. Une note générale facultative par session (1 000 caractères maximum) sera modifiable par l'employé pendant la session, en lecture seule après la sortie, avec historique des modifications prévu. Seule la colonne est préparée à ce stade.

## Politiques provisoires à faire approuver

Ces décisions de développement exigent une approbation client, vie privée et technique avant la production. M2.3b.1 ne met en œuvre aucune notification, minuterie, surveillance, fonction de géorepérage ou sortie automatique.

- **Panne de localisation :** consigner le motif technique observé de façon fiable, indiquer une surveillance indisponible/non concluante, signaler la session pour révision et notifier l’employé. Après 30 minutes sans accusé de réception, consigner ce fait et garder la session active; envoyer un autre rappel après environ une heure si le problème persiste. La panne GPS ou le silence seuls ne doivent jamais provoquer une sortie automatique.
- **Sortie de géofence :** délai de grâce proposé de 10 minutes après réception fiable d’indices de sortie suffisamment crédibles, avec notification de pointage de sortie. Continuer accorde une autre heure avant réévaluation et nouvelle notification. Après 30 minutes sans réponse, une sortie automatique n’est possible que si les exigences de preuve approuvées restent satisfaites; conserver les indices et exiger la révision administrative.
- **Durée excessive :** maximum configurable proposé de 16 heures, rappel à 8 heures, avertissement renforcé à 12 heures et final à 15 h 30, puis fermeture automatique proposée à 16 heures avec révision administrative obligatoire. Cette fermeture ne prouve pas que toute la durée écoulée a été travaillée.

La session reste active jusqu’à une sortie autorisée ou une fermeture distincte approuvée fondée sur des éléments indépendants suffisants. Les seuils, exceptions, instants de départ des délais, garanties de livraison et horodatages de fermeture restent à valider.

## Décisions encore ouvertes

1. Confirmez-vous formellement que le modèle de surveillance proposé pour les chantiers extérieurs est acceptable pour la V1?
2. Approuvez-vous le processus provisoire de sortie de géofence ci-dessus, avec notification, prolongation après « Continuer », preuves toujours suffisantes et révision administrative? Quelles exceptions et quels délais exacts faut-il retenir?
3. Le rayon final doit-il être 100 m, 150 m ou une autre tolérance après les tests de faisabilité?
4. Quelles preuves minimales doivent être exigées avant une fermeture automatique?
5. Quels seuils de précision, de fraîcheur et d'incertitude de limite retenir, et comment présenter la révision, sachant que la cible approuvée laisse le pointage possible sans localisation suffisante?
6. Les employés doivent-ils pointer une sortie et une nouvelle entrée pour le dîner ou les pauses?
7. Faut-il déduire automatiquement certaines pauses, ou attendre une règle confirmée?
8. Les totaux mensuels doivent-ils être calculés automatiquement à partir des sessions complètes validées, ou approuvés formellement par l'administrateur avant utilisation?
9. Pendant combien de temps faut-il conserver les résumés mensuels d'assiduité?
10. Approuvez-vous les rappels proposés à 8 h, 12 h et 15 h 30, sans fermeture fondée uniquement sur une notification sans réponse? Quelles actions et garanties de livraison prévoir?
11. Approuvez-vous le maximum configurable proposé de 16 heures et la fermeture avec révision administrative obligatoire? Quelles exceptions et quel horodatage de fermeture faut-il retenir?
12. Approuvez-vous la procédure de panne de localisation ci-dessus : motif fiable, surveillance non concluante/indisponible, révision, notification, absence d’accusé après 30 minutes et rappel après environ une heure, sans sortie automatique causée par la panne ou le silence seuls?
13. Quelles attentes souhaitez-vous communiquer aux employés qui utilisent leur téléphone personnel: tentatives de localisation aux pointages et surveillance extérieure ultérieure, batterie, notifications, refus de permission, téléphone éteint ou localisation désactivée?
14. Pendant combien de temps faut-il conserver séparément les données de localisation brutes, les sessions de travail, les résumés mensuels, les demandes de correction, les décisions administratives, les journaux d'audit et les sauvegardes?
15. Les décisions administratives liées à des employés identifiables peuvent-elles être conservées plus longtemps que les données GPS brutes, et selon quelle politique approuvée?
16. Quels champs doivent apparaître dans l'export CSV mensuel?
